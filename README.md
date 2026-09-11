# matvi-monitoring-agent

Agent privé permettant de récupérer les métriques système (CPU, mémoire, disque, réseau) et de les pousser vers une stack de monitoring externe (ex. Prometheus Pushgateway, VictoriaMetrics, NewRelic, etc.).

## 📦 Installation du chart

Ajoutez le dépôt Helm et installez le chart :

```bash
helm repo add matvi-charts https://charts.matvi-consulting.com
helm repo update
helm install my-agent matvi-monitoring-agent/matvi-monitoring-agent
```

### 🏗️ Déploiement via Terraform / CDKTF

Si vous déployez le chart via la ressource `helm_release`, utilisez les options suivantes :

```hcl
resource "helm_release" "matvi_monitoring_agent" {
  name       = "matvi-monitoring-agent"
  chart      = "matvi-monitoring-agent"
  repository = "https://charts.matvi-consulting.com"
  namespace  = "monitoring"
  version    = "0.6.2"

  wait            = true
  timeout         = 600
  atomic          = true
  cleanup_on_fail = true
}
```

| Option            | Pourquoi                                                                                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `atomic`          | **Indispensable.** Sans cette option, un install qui échoue laisse une release en état `failed` dans le cluster alors que Terraform ne l'a pas enregistrée dans son state. Le run suivant retente un install et échoue définitivement sur `cannot re-use a name that is still in use`, ce qui impose un `helm uninstall` manuel. Avec `atomic`, Helm nettoie tout seul et la pipeline reste rejouable. |
| `cleanup_on_fail` | Supprime les ressources nouvellement créées lors d'un upgrade raté, au lieu de les laisser orphelines.                                                                                                                                |
| `timeout`         | Le défaut de 300s est souvent trop court : le chart déploie des DaemonSets (`node-exporter`, `kubelet-cadvisor-pusher`), donc autant de pods à passer `Ready` qu'il y a de nœuds. Comptez large sur les gros clusters, sinon l'upgrade sort en `context deadline exceeded`. |

> `atomic` implique déjà `wait` ; le garder explicite ne coûte rien et rend l'intention lisible.

## ⚙️ Configuration

Le chart expose plusieurs valeurs personnalisables via `values.yaml`. Vous pouvez les surcharger lors de l’installation avec `--set` ou en fournissant un fichier personnalisé.

### Exemple d’installation avec un fichier de valeurs

```bash
helm install my-agent matvi-monitoring-agent/matvi-monitoring-agent -f values.yaml
```

### Principales valeurs disponibles

| Paramètre                 | Description                                               | Valeur par défaut                           |
| ------------------------- | --------------------------------------------------------- | ------------------------------------------- |
| `image.repository`        | Image Docker de l’agent                                   | `ghcr.io/matvi-consulting/monitoring-agent` |
| `image.tag`               | Tag de l’image à déployer                                 | `latest`                                    |
| `resources.limits.cpu`    | Limite CPU                                                | `200m`                                      |
| `resources.limits.memory` | Limite mémoire                                            | `256Mi`                                     |
| `push.url`                | URL de la cible de monitoring (Pushgateway / API / autre) | `""`                                        |
| `push.interval`           | Intervalle entre deux pushs                               | `30s`                                       |
| `nodeSelector`            | Contraintes de nœud                                       | `{}`                                        |

### 🌐 Sonde HTTP

Vérifie qu'une URL répond bien le code HTTP attendu et surveille l'expiration de son certificat. Les métriques portent les mêmes noms que celles du blackbox-exporter Prometheus (`probe_success`, `probe_http_status_code`, `probe_duration_seconds`, `probe_ssl_earliest_cert_expiry`), avec `job=http-probe` et `instance=<name de la sonde>`.

La sonde doit viser le **domaine public** du site, pas un Service interne : le trafic sort du cluster, résout le DNS public et négocie le TLS. Une panne DNS ou un certificat expiré sont donc détectés.

```yaml
httpProbe:
  enabled: true
  probes:
    - url: "https://www.mon-domaine.tld"
      name: "site-vitrine"        # label `instance` (défaut : probe-N)
      expectedStatus: "200,302"   # liste CSV, défaut : 200
    - url: "https://api.mon-domaine.tld/health"
```

| Paramètre | Description | Défaut |
| ----------- | ------------- | -------- |
| `httpProbe.enabled` | Déploie un pod dédié aux sondes | `false` |
| `httpProbe.probes` | Liste des sondes (`url` obligatoire, `name` et `expectedStatus` optionnels) | `[]` |
| `httpProbe.interval` | Secondes entre deux requêtes réelles | `60` |
| `httpProbe.tlsInterval` | Secondes entre deux lectures du certificat | `3600` |
| `httpProbe.connectTimeout` | Timeout de connexion de la sonde | `5` |
| `httpProbe.maxTime` | Durée maximale d'une sonde | `10` |
| `agent.httpProbe.pushInterval` | Intervalle de push des dernières mesures | `30` |

Deux rythmes découplés : la sonde réelle tourne toutes les `httpProbe.interval` secondes, mais la dernière mesure est repoussée à chaque `pushInterval`. C'est nécessaire, la push-gateway supprimant les métriques qu'elle sert : une série poussée moins souvent que l'intervalle de scrape de Prometheus apparaîtrait trouée, et `probe_success == 0` ne se déclencherait jamais.

Le pod tourne en mode `http-probe` (`ENABLE_HTTP_PROBE_ONLY=true`) : il ne scrape aucun exporter local et ne pousse donc pas de `monitoring_agent_up`. Activer `httpProbe.enabled` sans déclarer de sonde fait échouer le rendu du chart, plutôt que de déployer un pod muet.

### 🔐 Secrets nécessaires

Si votre agent doit pousser les métriques vers une cible sécurisée (API key, token, etc.), vous devez créer un secret Kubernetes avant d’installer le chart.

Exemple avec une clé API :

```bash
kubectl create secret generic monitoring-agent-secret \
  --from-literal=API_KEY="votre_api_key"
```

Ensuite, configurez le chart pour qu’il monte ce secret :

```yaml
secret:
  enabled: true
  name: monitoring-agent-secret
  keys:
    - API_KEY
```

## 🚀 Mise à jour

Pour mettre à jour le chart avec une nouvelle version :

```bash
helm repo update
helm upgrade my-agent matvi-monitoring-agent/matvi-monitoring-agent
```

## ❌ Désinstallation

Pour supprimer le chart :

```bash
helm uninstall my-agent
```
