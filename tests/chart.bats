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
