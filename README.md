# Validator Operations Safety Specification

A formally verified specification proving that our Cosmos SDK validator operations can never result in double-signing.

## The Problem

Running a Cosmos SDK validator means managing a process that signs blocks on behalf of delegators. If two instances of the same validator run simultaneously, both will sign blocks at the same height, triggering the chain's slashing mechanism. The result is permanent loss of staked funds. There is no undo.

Our validators run in Kubernetes. Upgrades, restarts, crashes, and recovery all involve pod lifecycle transitions. We need to be certain that no sequence of these events can ever produce two running pods for the same chain.

## The Approach

Rather than relying on checklists and hope, we modeled the entire validator lifecycle as a state machine in [Quint](https://github.com/informalsystems/quint) and mathematically verified that the critical safety property holds across all reachable states.

## What We Model

### Validator States

| State | Description |
|-------|-------------|
| `Running` | Pod is up and signing blocks |
| `Stopped` | Pod is terminated, no process running |
| `Halted` | Pod is alive but halted at upgrade height (not signing) |
| `Starting` | Pod is being created by k8s (not yet signing) |
| `Terminating` | Pod is shutting down |
| `Upgrading` | Image swap in progress |

### Operations

| Action | Description |
|--------|-------------|
| `StopValidator` | Operator deliberately stops a validator |
| `StartValidator` | Operator starts a stopped validator |
| `ChainHalt` | Chain halts at governance upgrade height |
| `PullImage` | Operator pulls and tags new container image |
| `RestartDeployment` | Operator issues k8s rollout restart (Recreate strategy) |
| `PodCrash` | Unexpected pod crash |
| `PodReady` | Pod finishes starting |
| `PodTerminated` | Pod finishes shutting down |
| `K8sAutoRestart` | Kubernetes deployment controller restarts a crashed pod |

### Chains

Three independent validators modeled concurrently:
- **Regen** (regen-1)
- **Althea** (althea)
- **Gravity Bridge** (gravity-bridge-3)

## Safety Properties Verified

| Property | Description |
|----------|-------------|
| `no_double_signing` | No chain ever has more than 1 pod running |
| `valid_pod_count` | Pod count is always 0 or 1 (never negative) |
| `running_means_pod` | Active states (Running/Halted/Starting/Terminating) always have exactly 1 pod |
| `stopped_means_no_pod` | Stopped state always has 0 pods |
| `upgrade_requires_image` | Restart deployment only happens after image is pulled |

## Verification Results

```
$ quint test validator_ops.qnt
validator_ops
    ok upgradeTest passed 1 test(s)
    ok crashRecoveryTest passed 1 test(s)
    ok multiChainTest passed 1 test(s)
    ok manualRestartTest passed 1 test(s)

  4 passing (45ms)

$ quint run --invariant=safety --max-samples=50000 --max-steps=30 validator_ops.qnt
[ok] No violation found (1925ms at 25974 traces/second).
```

50,000 random execution traces explored, up to 30 steps each, across all three chains operating concurrently. Zero violations.

## Test Scenarios

| Test | Scenario |
|------|----------|
| `upgradeTest` | Normal upgrade: halt at height, pull image, restart, terminate old, start new, ready |
| `crashRecoveryTest` | Pod crashes, terminates, k8s auto-restarts, becomes ready |
| `multiChainTest` | Regen upgrading while Althea crashes simultaneously, both recover safely |
| `manualRestartTest` | Operator manually stops and restarts a validator |

## Key Design Decision: Recreate Strategy

The Kubernetes deployment uses `strategy: Recreate` instead of `RollingUpdate`. This is critical:

- **RollingUpdate** starts the new pod before terminating the old one (brief overlap = double-signing)
- **Recreate** terminates the old pod completely before starting the new one (no overlap possible)

This is enforced in the spec: `restartDeployment` transitions to `Terminating` first, and the new pod can only start after `Stopped` is reached.

## Running the Spec

```bash
# Install Quint
npm i -g @informalsystems/quint

# Typecheck
quint typecheck validator_ops.qnt

# Run tests
quint test validator_ops.qnt

# Simulate with safety invariant check
quint run --invariant=safety --max-samples=50000 --max-steps=30 validator_ops.qnt

# Check specific invariant
quint run --invariant=no_double_signing --max-samples=100000 validator_ops.qnt
```

## Infrastructure

- **Node:** zaphod (192.168.6.56)
- **Orchestration:** Kubernetes with Recreate deployment strategy
- **Images:** Built via CI, pushed to GHCR, pulled and tagged on node
- **Specification Language:** [Quint](https://github.com/informalsystems/quint) by Informal Systems
- **MCP Integration:** Verified using [mcp-server-quint](https://github.com/dpdanpittman/mcp-server-quint)

## License

MIT
