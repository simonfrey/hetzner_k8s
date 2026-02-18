{{/*
Common ArgoCD Application metadata
*/}}
{{- define "root-app.syncPolicy" -}}
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  retry:
    limit: 5
    backoff:
      duration: 5s
      factor: 2
      maxDuration: 3m
{{- end -}}
