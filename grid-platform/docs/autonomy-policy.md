# Autonomy policy

Which actions an agent on this platform may take on its own, which it may only propose, and which no
agent identity may hold at all. A row is only real where RBAC enforces it: an approval-gated action
is one the agent's Role does not grant, and a never-delegated action is one no agent identity holds.

| Action class | Reversibility | Blast radius | Decision |
|---|---|---|---|
| read cluster state | nothing to undo | none | autonomous |
| restart one Pod of the agent's own workload | the controller replaces it | the agent's own workload | autonomous |
| change a ConfigMap in a tenant namespace | re-apply the previous manifest | one tenant | approval-gated |
| scale a tenant Deployment | scale it back | one tenant, and shared capacity | approval-gated |
| change RBAC | possible, but grants may be used before the revert | every identity the change touches | never delegated |
| delete a namespace | not reversible from the cluster | everything in the namespace | never delegated |
| rotate a credential | not reversible; consumers must be updated | every consumer of the credential | never delegated |
