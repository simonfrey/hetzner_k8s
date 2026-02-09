## Development rules

### Setup from 0

Make sure everything you do does not haec any prerequisites. We always "terraform destroy" and setup from 0. No state kept.

### Persistance

Whenever you change something, never apply anything in plance (e.g. via kubeapply from stdin), but rather make sure to 
persist the changes in the git repository. This way, we can always go back to a previous state if something goes wrong, 
and also have the changes documented for future reference.

## Debugging rules

### Kubernetes debugging with MCP

You have a "kubernetes" MCP connected with read-only permissions to the cluster. You can use this MCP to debug the cluster without risking any changes. 
Always prefer this MCP for debugging over any other method that might have write permissions.