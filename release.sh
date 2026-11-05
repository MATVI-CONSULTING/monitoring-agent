#!/usr/bin/env bash
# Lance le workflow GitHub Actions `release.yml` (workflow_dispatch) sur le
# dernier commit poussé de la branche par defaut.
# Le workflow crée lui-même le tag vX.Y.Z et la release : ce script ne crée
# ni tag ni release, il demande seulement la version.
#
# Usage : ./release.sh
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

info()  { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

confirm() {
  local reply
  read -r -p "$1 (y/N) " reply
  [[ "$reply" =~ ^[Yy]$ ]]
}

# --- Prérequis ---

command -v git >/dev/null || die "git introuvable"
command -v gh >/dev/null || die "GitHub CLI (gh) introuvable : brew install gh"
gh auth status >/dev/null 2>&1 || die "gh non authentifié : gh auth login"
git rev-parse --git-dir >/dev/null 2>&1 || die "Pas dans un dépôt git"
cd "$(git rev-parse --show-toplevel)"
[[ -f .github/workflows/release.yml ]] || die "Pas de .github/workflows/release.yml dans ce dépôt"

REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
BRANCH=$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name)

# --- Dernier commit poussé ---

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
fi
