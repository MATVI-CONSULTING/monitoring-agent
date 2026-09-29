# tests/chart.bats — rendu du chart.
#
# Les deploiements « satellites » (rabbitmq, bases de donnees) n'embarquent
# aucun node-exporter local. S'ils ne disent rien, config.sh retombe sur
# MODE=standard / ENABLE_STANDARD=true : l'agent scrape localhost:9100, echoue,
# et pousse `monitoring_agent_up{job="node-exporter"} 0` en boucle. La regle
# InstanceUpStatusDown declenche alors un critical permanent au nom du pod
# lui-meme. Verifie en production chez insitu-systems : alerte allumee du
# 11/09/2026 au 14/09/2026, sans aucun rapport avec l'etat du client.

setup() {
  CHART="$BATS_TEST_DIRNAME/../charts/monitoring-agent"
}

# Extrait la valeur d'une variable d'environnement d'un deploiement donne.
# Le rendu arrive sur stdin ; le nom du deploiement est un suffixe, le prefixe
# etant engendre par chart.fullname.
env_du_deploiement() {
  local deploiement="$1" variable="$2"
  python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get('kind') != 'Deployment': continue
    if not doc['metadata']['name'].endswith('$deploiement'): continue
    for e in doc['spec']['template']['spec']['containers'][0].get('env', []):
        if e['name'] == '$variable':
            print(e.get('value', '')); sys.exit(0)
"
}

@test "le deploiement rabbitmq desactive le push node-exporter" {
  rendu=$(helm template essai "$CHART" \
    --set rabbitmqMonitoring.enabled=true \
    --set rabbitmqMonitoring.endpoint=http://rmq:15692/metrics)
  valeur=$(printf '%s' "$rendu" | env_du_deploiement rabbitmq-monitoring ENABLE_STANDARD)
  [ "$valeur" = "false" ] || { echo "ENABLE_STANDARD vaut '$valeur', attendu 'false'"; false; }
}

@test "le deploiement bases de donnees desactive le push node-exporter" {
  rendu=$(helm template essai "$CHART" --set databaseMonitoring.enabled=true)
  valeur=$(printf '%s' "$rendu" | env_du_deploiement database-monitoring ENABLE_STANDARD)
  [ "$valeur" = "false" ] || { echo "ENABLE_STANDARD vaut '$valeur', attendu 'false'"; false; }
}

@test "le deploiement rabbitmq transmet la liste des files exclues" {
  # La virgule est echappee : helm la lit sinon comme un separateur de --set.
  rendu=$(helm template essai "$CHART" \
    --set rabbitmqMonitoring.enabled=true \
    --set rabbitmqMonitoring.endpoint=http://rmq:15692/metrics \
    --set 'rabbitmqMonitoring.excludedQueues=a.copy\,b.copy')
  valeur=$(printf '%s' "$rendu" | env_du_deploiement rabbitmq-monitoring RABBITMQ_EXCLUDED_QUEUES)
  [ "$valeur" = "a.copy,b.copy" ] || { echo "RABBITMQ_EXCLUDED_QUEUES vaut '$valeur'"; false; }
}

@test "le deploiement rabbitmq vise l'endpoint agrege, per-object en derive" {
  # L'agent lit DEUX endpoints : celui-ci, et le meme suffixe de /per-object.
  # La valeur doit donc rester la racine /metrics, sans suffixe.
  rendu=$(helm template essai "$CHART" \
    --set rabbitmqMonitoring.enabled=true \
    --set rabbitmqMonitoring.endpoint=http://rmq:15692/metrics)
  valeur=$(printf '%s' "$rendu" | env_du_deploiement rabbitmq-monitoring RABBITMQ_ENDPOINT)
  [ "$valeur" = "http://rmq:15692/metrics" ]
}

@test "appVersion du chart et tag de l'image de l'agent concordent" {
  # Les deux se bougent ensemble ou pas du tout : un chart publie avec une
  # appVersion qui ment sur l'image reellement deployee rend impossible de
  # savoir, depuis le cluster, quelle version de l'agent tourne.
  app=$(grep '^appVersion:' "$CHART/Chart.yaml" | tr -d '"' | awk '{print $2}')
  image=$(grep '^  image:' "$CHART/values.yaml" | head -1 | tr -d '"' | sed 's/.*://')
  [ "$app" = "$image" ] || { echo "appVersion=$app, image=$image"; false; }
}

@test "kube-state-metrics expose les labels de nodepool des trois clouds" {
  # Sans --metric-labels-allowlist, kube_node_labels ne porte aucun label :
  # le dashboard k8s-capacity ne pourrait ventiler ni par nodepool ni par type
  # d'instance. OVH (nodepool), EKS/Karpenter et AKS (agentpool) doivent y etre.
  rendu=$(helm template essai "$CHART")
  args=$(printf '%s' "$rendu" | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get('kind') != 'Deployment': continue
    if not doc['metadata']['name'].endswith('kube-state-metrics'): continue
    print(' '.join(doc['spec']['template']['spec']['containers'][0].get('args', [])))
")
  for label in nodepool node.kubernetes.io/instance-type karpenter.sh/nodepool \
               eks.amazonaws.com/nodegroup kubernetes.azure.com/agentpool; do
    case "$args" in
      *--metric-labels-allowlist=nodes=\[*"$label"*\]*) ;;
      *) echo "label $label absent de : $args"; false ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Sonde DNS : deployee par defaut, sur tous les clusters.
# ---------------------------------------------------------------------------

@test "la sonde DNS est deployee par defaut, en mode dedie" {
  rendu=$(helm template essai "$CHART")
  valeur=$(printf '%s' "$rendu" | env_du_deploiement dns-probe ENABLE_DNS_PROBE_ONLY)
  [ "$valeur" = "true" ] || { echo "ENABLE_DNS_PROBE_ONLY vaut '$valeur'"; false; }
}

@test "la sonde DNS lit ses hosts dans le kube-state-metrics du chart" {
  # Pas de RBAC : la liste vient de kube_ingress_path, via le Service KSM de
  # la meme release.
  rendu=$(helm template essai "$CHART" --namespace monitoring)
  valeur=$(printf '%s' "$rendu" | env_du_deploiement dns-probe DNS_PROBE_KSM_URL)
  service=$(printf '%s' "$rendu" | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if doc and doc.get('kind') == 'Service' and doc['metadata']['name'].endswith('kube-state-metrics'):
        print(doc['metadata']['name'])
")
  [ "$valeur" = "http://${service}.monitoring.svc:8080/metrics" ] || { echo "DNS_PROBE_KSM_URL vaut '$valeur'"; false; }
}

@test "la sonde DNS se desactive" {
  rendu=$(helm template essai "$CHART" --set dnsProbe.enabled=false)
  ! printf '%s' "$rendu" | grep -q 'name: essai-matvi-monitoring-agent-dns-probe$'
  ! printf '%s' "$rendu" | grep -q 'ENABLE_DNS_PROBE_ONLY'
}

@test "la sonde DNS transmet exclusions, resolveurs et external-dns" {
  rendu=$(helm template essai "$CHART" \
    --set 'dnsProbe.excludeHosts=^preview-.*' \
    --set 'dnsProbe.resolvers=9.9.9.9 1.1.1.1')
  [ "$(printf '%s' "$rendu" | env_du_deploiement dns-probe DNS_PROBE_EXCLUDE_HOSTS)" = "^preview-.*" ]
  [ "$(printf '%s' "$rendu" | env_du_deploiement dns-probe DNS_PROBE_RESOLVERS)" = "9.9.9.9 1.1.1.1" ]
  [ "$(printf '%s' "$rendu" | env_du_deploiement dns-probe EXTERNAL_DNS_SCRAPE_URL)" = "auto" ]
}

@test "external-dns desactive reste une chaine vide, pas auto" {
  # L'agent lit ${EXTERNAL_DNS_SCRAPE_URL-auto} : une variable absente vaut
  # auto, une variable vide desactive. Le chart doit donc poser la variable.
  rendu=$(helm template essai "$CHART" --set externalDns.scrapeUrl=)
  printf '%s' "$rendu" | python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get('kind') != 'Deployment' or not doc['metadata']['name'].endswith('dns-probe'): continue
    env = {e['name']: e.get('value') for e in doc['spec']['template']['spec']['containers'][0]['env']}
    assert 'EXTERNAL_DNS_SCRAPE_URL' in env, 'variable absente'
    assert env['EXTERNAL_DNS_SCRAPE_URL'] == '', repr(env['EXTERNAL_DNS_SCRAPE_URL'])
    sys.exit(0)
sys.exit('deploiement dns-probe absent')
"
}

# Les DaemonSets n'ont qu'un pod par node, cloue a ce node : ni l'autoscaler ni
# le scheduler ne peuvent le placer ailleurs. Sans priorite, un node rempli par
# des workloads ordinaires le laisse Pending pour toujours, et tout helm upgrade
# --wait expire. Verifie en production chez charlie-solutions le 29/09/2026 :
# node-exporter Pending sur un node dev plein, upgrades 0.8.0 et 0.9.0 en echec.

# Affiche le priorityClassName d'un DaemonSet (vide s'il est absent).
priorite_du_daemonset() {
  local daemonset="$1"
  python3 -c "
import sys, yaml
for doc in yaml.safe_load_all(sys.stdin):
    if not doc or doc.get('kind') != 'DaemonSet': continue
    if not doc['metadata']['name'].endswith('$daemonset'): continue
    print(doc['spec']['template']['spec'].get('priorityClassName', '')); sys.exit(0)
sys.exit('daemonset $daemonset absent')
"
}

@test "les daemonsets sont system-node-critical par defaut" {
  rendu=$(helm template essai "$CHART")
  for ds in node-exporter kubelet-cadvisor-pusher; do
    valeur=$(printf '%s' "$rendu" | priorite_du_daemonset "$ds")
    [ "$valeur" = "system-node-critical" ] || { echo "$ds : priorityClassName vaut '$valeur'"; false; }
  done
}

@test "la priorite d'un daemonset se surcharge et se desactive" {
  rendu=$(helm template essai "$CHART" \
    --set nodeExporter.priorityClassName=resource-guaranteed \
    --set kubeletCadvisorPusher.priorityClassName=)
  [ "$(printf '%s' "$rendu" | priorite_du_daemonset node-exporter)" = "resource-guaranteed" ]
  [ "$(printf '%s' "$rendu" | priorite_du_daemonset kubelet-cadvisor-pusher)" = "" ]
}
