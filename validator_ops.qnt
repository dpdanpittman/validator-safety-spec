// =============================================================================
// Validator Operations Safety Specification
// =============================================================================
// Models the lifecycle of Cosmos SDK validators running in Kubernetes.
// Proves that no upgrade, restart, or failure sequence can result in
// two instances of the same validator running simultaneously (double-signing).
//
// Chains: regen, althea, gravity
// Node: zaphod (192.168.6.56)
// Orchestration: k8s deployments with Recreate strategy
// =============================================================================

module validator_ops {

  // -------------------------------------------------------------------------
  // Types
  // -------------------------------------------------------------------------

  // Validator lifecycle states
  type ValidatorState =
    | Running       // Pod is up and signing blocks
    | Stopped       // Pod is terminated, no process running
    | Halted        // Pod is alive but halted at upgrade height (not signing)
    | Upgrading     // Image swap in progress, old pod terminated
    | Starting      // Pod is being created by k8s (not yet signing)
    | Terminating   // Pod is shutting down (still might be signing briefly)

  // Operator actions that can be taken
  type Action =
    | NoOp
    | StopValidator
    | StartValidator
    | BeginUpgrade
    | PullImage
    | RestartDeployment
    | ChainHalt        // Chain halts at upgrade height
    | PodCrash         // Unexpected pod crash
    | PodReady         // Pod finishes starting, becomes ready
    | PodTerminated    // Pod finishes terminating

  // Per-chain state
  type ChainState = {
    state: ValidatorState,
    podCount: int,
    imageReady: bool,       // New image pulled and tagged
    haltHeight: bool,       // Chain has reached upgrade halt height
  }

  // -------------------------------------------------------------------------
  // State
  // -------------------------------------------------------------------------

  val CHAINS = Set("regen", "althea", "gravity")

  var chains: str -> ChainState
  var lastAction: Action
  var lastChain: str

  // -------------------------------------------------------------------------
  // Initial state: all validators running normally
  // -------------------------------------------------------------------------

  action init = all {
    chains' = CHAINS.mapBy(_ => {
      state: Running,
      podCount: 1,
      imageReady: false,
      haltHeight: false,
    }),
    lastAction' = NoOp,
    lastChain' = "none",
  }

  // -------------------------------------------------------------------------
  // Actions
  // -------------------------------------------------------------------------

  // Operator deliberately stops a validator
  action stopValidator(chain: str): bool = all {
    chains.get(chain).state == Running,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Terminating,
    }),
    lastAction' = StopValidator,
    lastChain' = chain,
  }

  // Pod finishes terminating
  action podTerminated(chain: str): bool = all {
    chains.get(chain).state == Terminating,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Stopped,
      podCount: 0,
    }),
    lastAction' = PodTerminated,
    lastChain' = chain,
  }

  // Operator starts a stopped validator
  action startValidator(chain: str): bool = all {
    chains.get(chain).state == Stopped,
    chains.get(chain).podCount == 0,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Starting,
      podCount: 1,
    }),
    lastAction' = StartValidator,
    lastChain' = chain,
  }

  // Pod finishes starting and becomes ready (running)
  action podReady(chain: str): bool = all {
    chains.get(chain).state == Starting,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Running,
    }),
    lastAction' = PodReady,
    lastChain' = chain,
  }

  // Chain halts at governance upgrade height
  action chainHalt(chain: str): bool = all {
    chains.get(chain).state == Running,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Halted,
      haltHeight: true,
    }),
    lastAction' = ChainHalt,
    lastChain' = chain,
  }

  // Operator pulls and tags new image (can happen anytime)
  action pullImage(chain: str): bool = all {
    chains.get(chain).haltHeight == true,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      imageReady: true,
    }),
    lastAction' = PullImage,
    lastChain' = chain,
  }

  // Operator issues rollout restart (Recreate strategy)
  // Recreate strategy: terminates old pod FIRST, then starts new one
  action restartDeployment(chain: str): bool = all {
    or {
      chains.get(chain).state == Halted,
      chains.get(chain).state == Running,
      chains.get(chain).state == Stopped,
    },
    chains.get(chain).imageReady == true,
    // Recreate strategy: old pod goes to Terminating first
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: if (chains.get(chain).state == Stopped) Starting
             else Terminating,
      podCount: if (chains.get(chain).state == Stopped) 1
                else chains.get(chain).podCount,
    }),
    lastAction' = RestartDeployment,
    lastChain' = chain,
  }

  // After Recreate termination completes, k8s starts the new pod
  action recreateStart(chain: str): bool = all {
    chains.get(chain).state == Stopped,
    chains.get(chain).imageReady == true,
    chains.get(chain).haltHeight == true,
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Starting,
      podCount: 1,
      haltHeight: false,  // Reset: new binary handles the upgrade
      imageReady: false,   // Reset: image consumed
    }),
    lastAction' = StartValidator,
    lastChain' = chain,
  }

  // Pod crashes unexpectedly
  action podCrash(chain: str): bool = all {
    or {
      chains.get(chain).state == Running,
      chains.get(chain).state == Halted,
      chains.get(chain).state == Starting,
    },
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Terminating,
    }),
    lastAction' = PodCrash,
    lastChain' = chain,
  }

  // K8s restarts crashed pod automatically (deployment controller)
  action k8sAutoRestart(chain: str): bool = all {
    chains.get(chain).state == Stopped,
    chains.get(chain).podCount == 0,
    // K8s deployment controller creates a new pod
    chains' = chains.set(chain, {
      ...chains.get(chain),
      state: Starting,
      podCount: 1,
    }),
    lastAction' = StartValidator,
    lastChain' = chain,
  }

  // -------------------------------------------------------------------------
  // Step: any chain, any action
  // -------------------------------------------------------------------------

  action step = {
    nondet chain = CHAINS.oneOf()
    any {
      stopValidator(chain),
      podTerminated(chain),
      startValidator(chain),
      podReady(chain),
      chainHalt(chain),
      pullImage(chain),
      restartDeployment(chain),
      recreateStart(chain),
      podCrash(chain),
      k8sAutoRestart(chain),
    }
  }

  // -------------------------------------------------------------------------
  // Invariants (Safety Properties)
  // -------------------------------------------------------------------------

  // CRITICAL: No chain ever has more than 1 pod
  val no_double_signing = CHAINS.forall(chain =>
    chains.get(chain).podCount <= 1
  )

  // Pod count is always 0 or 1 (never negative)
  val valid_pod_count = CHAINS.forall(chain =>
    chains.get(chain).podCount >= 0 and chains.get(chain).podCount <= 1
  )

  // If a validator is Running or Halted or Starting, it must have exactly 1 pod
  val running_means_pod = CHAINS.forall(chain => {
    val s = chains.get(chain)
    (s.state == Running or s.state == Halted or s.state == Starting or s.state == Terminating)
      .implies(s.podCount == 1)
  })

  // If a validator is Stopped, it must have 0 pods
  val stopped_means_no_pod = CHAINS.forall(chain =>
    chains.get(chain).state == Stopped implies chains.get(chain).podCount == 0
  )

  // Image must be pulled before restart
  val upgrade_requires_image = CHAINS.forall(chain =>
    (lastAction == RestartDeployment and lastChain == chain)
      .implies(chains.get(chain).imageReady == true)
  )

  // Combined safety invariant
  val safety = and {
    no_double_signing,
    valid_pod_count,
    running_means_pod,
    stopped_means_no_pod,
  }

  // -------------------------------------------------------------------------
  // Tests
  // -------------------------------------------------------------------------

  // Normal upgrade flow: halt -> pull -> restart -> terminate -> start -> ready
  run upgradeTest = {
    init
      .then(chainHalt("regen"))
      .then(pullImage("regen"))
      .then(restartDeployment("regen"))
      .then(podTerminated("regen"))
      .then(recreateStart("regen"))
      .then(podReady("regen"))
      .then(all { assert(safety), chains' = chains, lastAction' = lastAction, lastChain' = lastChain })
  }

  // Crash and auto-recovery
  run crashRecoveryTest = {
    init
      .then(podCrash("althea"))
      .then(podTerminated("althea"))
      .then(k8sAutoRestart("althea"))
      .then(podReady("althea"))
      .then(all { assert(safety), chains' = chains, lastAction' = lastAction, lastChain' = lastChain })
  }

  // Multiple chains operating independently
  run multiChainTest = {
    init
      .then(chainHalt("regen"))
      .then(podCrash("althea"))
      .then(pullImage("regen"))
      .then(podTerminated("althea"))
      .then(restartDeployment("regen"))
      .then(k8sAutoRestart("althea"))
      .then(podTerminated("regen"))
      .then(podReady("althea"))
      .then(recreateStart("regen"))
      .then(podReady("regen"))
      .then(all { assert(safety), chains' = chains, lastAction' = lastAction, lastChain' = lastChain })
  }

  // Stop and manual restart
  run manualRestartTest = {
    init
      .then(stopValidator("gravity"))
      .then(podTerminated("gravity"))
      .then(startValidator("gravity"))
      .then(podReady("gravity"))
      .then(all { assert(safety), chains' = chains, lastAction' = lastAction, lastChain' = lastChain })
  }
}
