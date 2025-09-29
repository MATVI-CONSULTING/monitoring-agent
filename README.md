# monitoring-agent

Agent privé permettant de récupérer les métriques système (CPU, mémoire, disque, réseau) et de les pousser vers la stack de monitoring.

## installer le chart

```bash
helm repo add monitoring-agent https://matvi-consulting.github.io/monitoring-agent/charts
helm repo update
helm install my-agent monitoring-agent/monitoring-agent
```
