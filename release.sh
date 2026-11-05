#!/usr/bin/env bash
# Lance le workflow GitHub Actions `release.yml` (workflow_dispatch) sur le
# dernier commit poussé de la branche par defaut.
# Le workflow crée lui-même le tag vX.Y.Z et la release : ce script ne crée
# ni tag ni release, il demande seulement la version.
#
# Usage :
#   ./release.sh                              release (interactive)
#   ./release.sh --cleanup [--keep N]         liste ce qui serait supprimé (dry-run)
#   ./release.sh --cleanup --apply [--keep N] supprime, après confirmation
#
# Nettoyage : garde le dernier patch de chaque mineure + les N dernières
# releases (10 par défaut). Le reste est supprimé : images GHCR, releases
# GitHub et tags. Les tags d'image flottants (latest, 1, 1.14) ne sont jamais
# supprimés. Scopes gh requis : read:packages (+ delete:packages pour --apply).

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

CLEANUP_KEEP_DEFAULT=10

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

confirm() {
  local reply
  read -r -p "$1 (y/N) " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

usage() { sed -n '7,10p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

# --- Logique pure (testée par tests/release.bats) ---

# stdin : tags. stdout : tags vX.Y.Z à supprimer, du plus récent au plus ancien.
# Gardés : les $1 plus récents, et le plus récent de chaque mineure.
tags_to_delete() {
  local keep=$1
  grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -rV | awk -v keep="$keep" '
    { split(substr($0, 2), v, "."); minor = v[1] "." v[2] }
    NR <= keep         { seen[minor] = 1; next }
    !(minor in seen)   { seen[minor] = 1; next }
    { print }'
}

# stdin : tags existants. Succès (et affiche le tag fautif) si un patch >= celui
# de $1 existe déjà dans la même mineure : la version a déjà été publiée, peut-
# être puis supprimée par --cleanup, et ne doit jamais être republiée.
version_superseded() {
  local maj min pat
  IFS=. read -r maj min pat <<<"$1"
  grep -E "^v${maj}\.${min}\.[0-9]+$" | sort -rV | awk -F. -v p="$pat" '$3 >= p { print; found = 1; exit } END { exit !found }'
}

# stdin : JSON des versions du paquet GHCR. $1 : tags git à supprimer.
# stdout : « id digest » des versions taguées dont TOUS les tags sont à
# supprimer. Une version qui porte aussi latest, 1 ou 1.14 est gardée ; une
# version sans tag (enfant d'un index multi-arch) n'est jamais retenue ici.
package_versions_to_delete() {
  jq -r --arg del "$1" '
    ($del | split("\n") | map(select(. != "") | ltrimstr("v"))) as $set
    | .[]
    | (.metadata.container.tags // []) as $tags
    | select(($tags | length) > 0 and (($tags - $set) | length) == 0)
    | "\(.id) \(.name)"'
}

# $1 : digests enfants des index supprimés, $2 : ceux des index gardés.
# stdout : enfants à supprimer (non référencés par une image gardée).
orphan_children() {
  awk 'NR == FNR { if ($0 != "") kept[$0] = 1; next } $0 != "" && !($0 in kept) && !seen[$0]++' \
    <(printf '%s\n' "$2") <(printf '%s\n' "$1")
}

# stdin : release.yml. $1 : nom du dépôt, $2 : nom du chart (Chart.yaml).
# stdout : nom du paquet GHCR publié par le workflow, rien s'il n'en publie pas.
#   IMAGE_NAME: ${{ github.repository }}      -> <dépôt>         (image Docker)
#   oci://ghcr.io/<owner>/<chemin>            -> <chemin>/<chart> (chart OCI)
ghcr_package_from_workflow() {
  local wf oci
  wf=$(cat)
  oci=$(sed -nE 's#.*oci://ghcr\.io/[^/[:space:]]+/([^[:space:]"]+).*#\1#p' <<<"$wf" | head -n 1)
  if [[ -n "$oci" && -n "$2" ]]; then
    echo "${oci%/}/$2"
  elif grep -qE 'IMAGE_NAME:[[:space:]]*\$\{\{[[:space:]]*github\.repository[[:space:]]*\}\}' <<<"$wf"; then
    tr '[:upper:]' '[:lower:]' <<<"$1"
  fi
}

# --- Commun ---

preflight() {
  command -v git >/dev/null || die "git introuvable"
  command -v gh >/dev/null || die "GitHub CLI (gh) introuvable : brew install gh"
  gh auth status >/dev/null 2>&1 || die "gh non authentifié : gh auth login"
  git rev-parse --git-dir >/dev/null 2>&1 || die "Pas dans un dépôt git"
  cd "$(git rev-parse --show-toplevel)"
  [[ -f .github/workflows/release.yml ]] || die "Pas de .github/workflows/release.yml dans ce dépôt"

  REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
  BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)
}

# --- GHCR ---

# Préfixe d'API du paquet (organisation ou utilisateur).
ghcr_api_base() {
  local owner_type
  owner_type=$(gh api "repos/$REPO" --jq .owner.type)
  if [[ "$owner_type" == Organization ]]; then
    echo "orgs/${REPO%%/*}/packages/container/${GHCR_PACKAGE//\//%2F}"
  else
    echo "user/packages/container/${GHCR_PACKAGE//\//%2F}"
  fi
}

ghcr_token() {
  curl -fsS -u "x:$(gh auth token)" \
    "https://ghcr.io/token?scope=repository:${GHCR_IMAGE}:pull" | jq -r .token
}

# Digests des manifestes enfants (plateformes, attestations) d'un index ; rien
# pour un manifeste simple (chart OCI, image mono-arch).
ghcr_children() {
  curl -fsS -H "Authorization: Bearer $GHCR_BEARER" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "https://ghcr.io/v2/${GHCR_IMAGE}/manifests/$1" | jq -r '.manifests[]?.digest' \
    || warn "Manifeste $1 illisible : ses enfants éventuels ne seront pas supprimés"
}

# Remplit GHCR_DELETE (« id digest » : index puis enfants orphelins).
ghcr_plan() {
  local del_tags=$1 versions del_index kept_digests del_children="" kept_children="" d orphans
  GHCR_DELETE=""
  versions=$(gh api --paginate "$GHCR_BASE/versions?per_page=100" --jq '.[]' | jq -s .)

  del_index=$(package_versions_to_delete "$del_tags" <<<"$versions")
  [[ -z "$del_index" ]] && return 0

  kept_digests=$(jq -r --arg del "$(cut -d' ' -f2 <<<"$del_index")" '
    ($del | split("\n")) as $d
    | .[] | select((.metadata.container.tags // []) | length > 0)
    | .name | select(IN($d[]) | not)' <<<"$versions")

  GHCR_BEARER=$(ghcr_token)
  for d in $(cut -d' ' -f2 <<<"$del_index"); do del_children+=$(ghcr_children "$d")$'\n'; done
  for d in $kept_digests; do kept_children+=$(ghcr_children "$d")$'\n'; done

  orphans=$(orphan_children "$del_children" "$kept_children")
  GHCR_DELETE=$del_index
  if [[ -n "$orphans" ]]; then
    GHCR_DELETE+=$'\n'$(jq -r --arg o "$orphans" '
      ($o | split("\n")) as $set
      | .[] | select(((.metadata.container.tags // []) | length) == 0 and (.name | IN($set[])))
      | "\(.id) \(.name)"' <<<"$versions")
  fi
}

# Échoue (et explique) si un des scopes gh demandés manque.
has_scopes() {
  local scopes s
  scopes=$(gh api -i user 2>/dev/null | tr -d '\r' | sed -n 's/^[Xx]-[Oo][Aa]uth-[Ss]copes: //p')
  for s in "$@"; do
    if [[ ", $scopes," != *", $s,"* ]]; then
      warn "Scope gh manquant : $s. Lancer : gh auth refresh -h github.com -s $(IFS=,; echo "$*")"
      return 1
    fi
  done
}

# --- Nettoyage ---

main_cleanup() {
  local apply=0 keep=$CLEANUP_KEEP_DEFAULT del_tags n_tags n_ghcr id digest t
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --apply) apply=1 ;;
      --keep) keep=${2:?--keep N}; shift ;;
      *) die "Option inconnue : $1" ;;
    esac
    shift
  done
  [[ "$keep" =~ ^[0-9]+$ ]] || die "--keep attend un entier"

  preflight
  command -v jq >/dev/null || die "jq introuvable : brew install jq"
  command -v curl >/dev/null || die "curl introuvable"

  info "Récupération des tags de origin..."
  git fetch --quiet --tags --prune-tags --force origin

  del_tags=$(git tag --list | tags_to_delete "$keep")
  if [[ -z "$del_tags" ]]; then
    info "Rien à nettoyer (rétention : dernier patch par mineure + $keep dernières releases)"
    return 0
  fi
  n_tags=$(wc -l <<<"$del_tags" | tr -d ' ')

  # Paquet GHCR : GHCR_PACKAGE, sinon déduit de release.yml (vide = aucun).
  local chart_file chart_name=""
  chart_file=$(git ls-files | grep -E '(^|/)Chart\.yaml$' | head -n 1 || true)
  [[ -n "$chart_file" ]] && chart_name=$(sed -n 's/^name:[[:space:]]*//p' "$chart_file" | head -n 1 | tr -d "\"' ")
  GHCR_PACKAGE=${GHCR_PACKAGE:-$(ghcr_package_from_workflow "${REPO#*/}" "$chart_name" <.github/workflows/release.yml)}
  GHCR_DELETE=""
  if [[ -z "$GHCR_PACKAGE" ]]; then
    info "release.yml ne publie pas sur GHCR : seuls tags et releases sont nettoyés"
  else
    GHCR_IMAGE=$(tr '[:upper:]' '[:lower:]' <<<"${REPO%%/*}/$GHCR_PACKAGE")
    if [[ "$apply" == 1 ]]; then
      has_scopes read:packages delete:packages || die "Images GHCR non nettoyables sans ces scopes"
    fi
    GHCR_BASE=$(ghcr_api_base)
    if ! has_scopes read:packages; then
      warn "Dry-run sans les images GHCR"
    elif gh api "$GHCR_BASE" >/dev/null 2>&1; then
      info "Analyse de ghcr.io/$GHCR_IMAGE..."
      ghcr_plan "$del_tags"
    else
      warn "Paquet GHCR $GHCR_PACKAGE introuvable (GHCR_PACKAGE=... pour un autre nom) : images ignorées"
    fi
  fi
  n_ghcr=$(grep -c . <<<"$GHCR_DELETE" || true)

  echo
  info "Rétention : dernier patch par mineure + $keep dernières releases"
  info "Tags + releases à supprimer ($n_tags) :"
  printf '  %s\n' $del_tags
  info "Versions d'image GHCR à supprimer ($n_ghcr, index + enfants orphelins) :"
  [[ -n "$GHCR_DELETE" ]] && sed 's/^/  /' <<<"$GHCR_DELETE"
  echo

  if [[ "$apply" != 1 ]]; then
    info "Dry-run : rien n'a été supprimé. Relancer avec --apply pour supprimer."
    return 0
  fi
  warn "Suppression IRRÉVERSIBLE : un client épinglé sur une de ces versions ne pourra plus la tirer."
  confirm "Supprimer $n_tags tags/releases et $n_ghcr versions d'image ?" || { info "Nettoyage annulé"; return 0; }

  # Images d'abord : si la suite échoue, un nouveau --cleanup retrouve les
  # images à partir des tags encore présents.
  while read -r id digest; do
    [[ -z "$id" ]] && continue
    gh api -X DELETE "$GHCR_BASE/versions/$id" >/dev/null \
      && info "Image supprimée : $digest" || warn "Échec suppression image $digest (id $id)"
  done <<<"$GHCR_DELETE"

  for t in $del_tags; do
    if gh release view "$t" --repo "$REPO" >/dev/null 2>&1; then
      gh release delete "$t" --repo "$REPO" --cleanup-tag --yes || { warn "Échec release $t"; continue; }
    else
      git push --quiet origin ":refs/tags/$t" || { warn "Échec tag $t"; continue; }
    fi
    git tag -d "$t" >/dev/null 2>&1 || true
    info "Supprimé : $t"
  done
  info "Nettoyage terminé."
}

# --- Release ---

main_release() {
  preflight

  info "Récupération de origin/$BRANCH et des tags..."
  git fetch --quiet --tags origin "$BRANCH"
  COMMIT=$(git rev-parse "origin/$BRANCH")

  if [[ "$(git rev-parse HEAD)" != "$COMMIT" ]]; then
    warn "HEAD local ($(git rev-parse --short HEAD)) diffère de origin/$BRANCH ($(git rev-parse --short "$COMMIT"))."
    warn "C'est origin/$BRANCH qui sera releasé (les commits non poussés sont ignorés)."
  fi
  if [[ -n "$(git status --porcelain)" ]]; then
    warn "Modifications locales non commitées : elles ne font pas partie de la release."
  fi

  # --- Version ---

  # Dernière release GitHub (« Latest »), sinon dernier tag vX.Y.Z de la branche.
  LAST_TAG=$(gh release view --repo "$REPO" --json tagName -q .tagName 2>/dev/null || true)
  if [[ ! "$LAST_TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    LAST_TAG=$(git tag --list 'v[0-9]*' --merged "$COMMIT" --sort=-v:refname | head -n 1)
  fi

  # Chart Helm : la version doit égaler `version` du Chart.yaml au commit releasé.
  CHART_FILE=""
  CHART_VERSION=""
  CHARTS=$(git ls-tree -r --name-only "$COMMIT" | grep -E '(^|/)Chart\.yaml$' || true)
  if [[ -n "$CHARTS" ]]; then
    if [[ $(printf '%s\n' "$CHARTS" | wc -l) -eq 1 ]]; then
      CHART_FILE=$CHARTS
      CHART_VERSION=$(git show "$COMMIT:$CHART_FILE" | sed -n 's/^version:[[:space:]]*//p' | tr -d "\"' ")
    else
      warn "Plusieurs Chart.yaml : vérification de version ignorée."
    fi
  fi

  SUGGEST=""
  if [[ -n "$CHART_VERSION" ]]; then
    SUGGEST=$CHART_VERSION
  elif [[ -n "$LAST_TAG" ]]; then
    IFS=. read -r MAJ MIN PAT <<<"${LAST_TAG#v}"
    SUGGEST="$MAJ.$MIN.$((PAT + 1))"
  fi

  echo
  info "Dépôt          : $REPO"
  info "Branche        : $BRANCH"
  info "Commit         : $(git log -1 --format='%h %s' "$COMMIT")"
  info "Dernière release : ${LAST_TAG:-aucune}"
  [[ -n "$CHART_VERSION" ]] && info "Chart.yaml     : $CHART_FILE (version $CHART_VERSION)"
  echo

  read -r -p "Version à releaser, X.Y.Z sans v${SUGGEST:+ [$SUGGEST]} : " VERSION
  VERSION=${VERSION:-$SUGGEST}
  [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Version invalide '$VERSION' (attendu X.Y.Z, sans v)"

  TAG="v$VERSION"
  if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
    if [[ "$VERSION" == "$CHART_VERSION" ]]; then
      die "Le tag $TAG existe déjà : passer version de $CHART_FILE à une nouvelle version, pousser, puis relancer"
    fi
    die "Le tag $TAG existe déjà"
  fi
  # Un tag supprimé par --cleanup a toujours un patch supérieur gardé dans sa
  # mineure : refuser évite de republier une version déjà distribuée.
  if SUPERSEDED=$(git tag --list | version_superseded "$VERSION"); then
    die "$SUPERSEDED existe déjà : $VERSION a pu être publiée puis nettoyée, choisir une version plus haute"
  fi
  if [[ -n "$CHART_VERSION" && "$CHART_VERSION" != "$VERSION" ]]; then
    die "$CHART_FILE est en $CHART_VERSION sur origin/$BRANCH : passer version à $VERSION, pousser, puis relancer"
  fi

  read -r -p "Notes de release (une ligne, vide = notes par défaut du workflow) : " NOTES

  # --- Confirmation ---

  echo
  info "Résumé :"
  echo "  - Dépôt   : $REPO"
  echo "  - Version : $VERSION (tag $TAG)"
  echo "  - Commit  : $COMMIT"
  echo "  - Notes   : ${NOTES:-<par défaut>}"
  echo
  confirm "Lancer le workflow release.yml ?" || { info "Release annulée"; exit 0; }

  # --- Lancement ---

  ARGS=(-f "version=$VERSION" -f "commit=$COMMIT")
  [[ -n "$NOTES" ]] && ARGS+=(-f "notes=$NOTES")

  # Marge de 30 s pour un éventuel décalage d'horloge (date BSD sur macOS, GNU sinon).
  SINCE=$(date -u -v-30S +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d '30 seconds ago' +%Y-%m-%dT%H:%M:%SZ)
  gh workflow run release.yml --repo "$REPO" --ref "$BRANCH" "${ARGS[@]}"
  info "Workflow lancé."

  # Le run met quelques secondes à apparaître : on prend le premier créé après SINCE.
  RUN_ID=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    sleep 3
    RUN_ID=$(gh run list --repo "$REPO" --workflow=release.yml --event workflow_dispatch --limit 5 \
      --json databaseId,createdAt \
      --jq "map(select(.createdAt >= \"$SINCE\")) | last | .databaseId // empty")
    [[ -n "$RUN_ID" ]] && break
  done

  if [[ -z "$RUN_ID" ]]; then
    warn "Run introuvable pour l'instant : gh run list --repo $REPO --workflow=release.yml"
    exit 0
  fi

  info "Run : https://github.com/$REPO/actions/runs/$RUN_ID"
  if confirm "Suivre l'exécution ?"; then
    gh run watch "$RUN_ID" --repo "$REPO" --exit-status
    info "Release $VERSION terminée : https://github.com/$REPO/releases/tag/$TAG"
    info "Vieilles versions : ./release.sh --cleanup (dry-run)"
  fi
}

main() {
  set -euo pipefail
  case "${1:-}" in
    "") main_release ;;
    --cleanup) shift; main_cleanup "$@" ;;
    -h|--help) usage ;;
    *) usage >&2; exit 2 ;;
  esac
}

# Sourcé (tests) : définit les fonctions sans rien lancer.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
