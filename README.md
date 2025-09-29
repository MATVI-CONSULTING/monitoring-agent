# matvi-monitoring-agent

Agent privé permettant de récupérer les métriques système (CPU, mémoire, disque, réseau) et de les pousser vers une stack de monitoring externe (ex. Prometheus Pushgateway, VictoriaMetrics, NewRelic, etc.).

## 📦 Installation du chart

Ajoutez le dépôt Helm et installez le chart :

```bash
helm repo add matvi-charts https://charts.matvi-consulting.com
helm repo update
helm install my-agent matvi-monitoring-agent/matvi-monitoring-agent
```

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
