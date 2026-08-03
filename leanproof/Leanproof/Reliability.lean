import Mathlib

/-!
# Formal verification of the EMSx realtime-rollout evaluation

Machine-checked with Lean 4 + mathlib (v4.33.0-rc1).  The theorems below
are the mathematical backbone of the score and of the statistical
endpoints.  They are convention-independent: they hold for any choice of
(dummy, model, anticipative) costs.

Reported numbers (70 official sites, original leak-free EMSx forecast
semantics, forecast origin row t+1, settlement-aligned horizon-96 index):

  environment-consistent track (oracle = backward DP sharing the
  environment's empty-battery discharge credit; candidate unconstrained):
      mean score = 0.997348, score LCB = 0.995720,
      paired LCB vs wdwe2_k20 = 0.917831, all_passed = true.
      Audit: candidate infeasible-discharge rate 0.996, oracle 1.0,
      baseline 7.1e-5 -> the near-perfect score measures exploit parity.

  physical track (oracle = independent LP with SOC in [0,1]; candidate
  restricted to the energy-conserving action set U(soc)):
      candidate mean score = 0.579, baseline wdwe2_k20 = 0.768
      -> the physically honest evaluation favors the baseline.

  Theorems 1-4 verify abstract properties only (score in [0,1] under
  stated premises; resample mean >= site minimum; paired resample mean
  >= min_pair; infimum of achievable costs is a lower bound).  They do
  not assert that any reported controller is causal-feasible, that the
  numerical oracles equal their mathematical definitions, or that score
  <= 1 holds empirically for a particular oracle.

1. `score_mem_Icc`          : causal controller ⟹ score ∈ [0,1].
2. `resample_mean_ge_min'`  : every bootstrap resample mean ≥ min score
   (0.9546 in the environment-consistent track).  A theorem, not a
   Monte-Carlo result; it is a fact about the observed 70 scores only.
3. `paired_mean_ge_min'`    : 70/70 sites win ⟹ paired resample mean ≥
   min_pair > 0, so the paired LCB > 0 is also a theorem.
4. `dpValue_lower_bound'`   : the perfect-prediction DP is a lower bound
   on every policy's total cost (hence an upper bound on score).
-/

namespace EmsxProof

/-! ## 1. Score ∈ [0,1] for a causal controller -/

/-- gain ≤ upper_gain when the model cannot beat perfect foresight. -/
theorem gain_le_upper_gain
    (dummy model anticip : ℝ) (h : model ≥ anticip) :
    dummy - model ≤ dummy - anticip := by
  linarith

/-- Score = gain / upper_gain ∈ [0,1] under causality + improvement. -/
theorem score_mem_Icc
    (dummy model anticip : ℝ)
    (h_anticip : model ≥ anticip)
    (h_gain : 0 ≤ dummy - model)
    (h_upper : 0 < dummy - anticip) :
    (dummy - model) / (dummy - anticip) ∈ Set.Icc (0 : ℝ) 1 := by
  constructor
  · positivity
  · rw [div_le_iff₀ h_upper]
    linarith

/-! ## 2. Bootstrap LCB ≥ site minimum (Finset.min' formulation) -/

/-- Concrete, computable version for the 70-site vector: every resample
mean is ≥ the minimum of the 70 site scores.  `Finset.min'` is the
minimum of a nonempty finite set of reals. -/
theorem resample_mean_ge_min'
    {n : ℕ} [NeZero n] (scores : Fin n → ℝ) (idx : Fin n → Fin n) :
    let m : ℝ := (Finset.univ.image (fun i : Fin n => scores i)).min'
      ⟨scores 0, by simp⟩
    (∑ i : Fin n, scores (idx i)) / (n : ℝ) ≥ m := by
  intro m
  have hge : ∀ i : Fin n, m ≤ scores (idx i) := by
    intro i
    dsimp [m]
    exact Finset.min'_le (s := Finset.univ.image (fun j : Fin n => scores j))
      (scores (idx i)) (by simp)
  have hsum : (n : ℝ) * m ≤ ∑ i : Fin n, scores (idx i) := by
    calc
      (n : ℝ) * m = ∑ _ : Fin n, m := by simp [Finset.card_fin, mul_comm]
      _ ≤ ∑ i : Fin n, scores (idx i) := by
        exact Finset.sum_le_sum (fun i _ => hge i)
  have hn : (0 : ℝ) < (n : ℝ) := by exact_mod_cast (NeZero.pos n)
  rw [ge_iff_le]
  rw [le_div_iff₀ hn]
  nlinarith

/-! ## 3. Paired resample mean ≥ min_pair > 0 -/

/-- If candidate ≥ baseline on every site and the minimum paired gain is
`min_pair`, then every paired resample mean is ≥ min_pair. -/
theorem paired_resample_mean_ge_min'
    {n : ℕ} [NeZero n] (cand base : Fin n → ℝ)
    (h_sites : ∀ i, cand i ≥ base i)
    (min_pair : ℝ)
    (h_min : min_pair = (Finset.univ.image (fun i : Fin n => cand i - base i)).min'
      ⟨cand 0 - base 0, by simp⟩)
    (h_min_pos : 0 < min_pair) :
    ∀ idx : Fin n → Fin n,
      (∑ i, (cand (idx i) - base (idx i))) / (n : ℝ) ≥ min_pair := by
  intro idx
  have hge : ∀ i : Fin n, min_pair ≤ cand (idx i) - base (idx i) := by
    intro i
    rw [h_min]
    exact Finset.min'_le (s := Finset.univ.image (fun j : Fin n => cand j - base j))
      (cand (idx i) - base (idx i)) (by simp)
  have hsum : (n : ℝ) * min_pair ≤ ∑ i, (cand (idx i) - base (idx i)) := by
    calc
      (n : ℝ) * min_pair = ∑ _ : Fin n, min_pair := by simp [Finset.card_fin, mul_comm]
      _ ≤ ∑ i, (cand (idx i) - base (idx i)) := by
        exact Finset.sum_le_sum (fun i _ => hge i)
  have hn : (0 : ℝ) < (n : ℝ) := by exact_mod_cast (NeZero.pos n)
  rw [ge_iff_le]
  rw [le_div_iff₀ hn]
  nlinarith

/-! ## 4. Perfect-prediction DP is a lower bound on total cost -/

/-- Realized net-demand trajectory (exactly the settlement row values the
simulator uses: `load - pv` at row `t+96+1`). -/
structure Trajectory (H : ℕ) where
  z : Fin H → ℝ

/-- Stage cost: step `t`, control `u`, realized demand `z`.  This is the
EMSx `compute_stage_cost(battery, prices, t, control, net_energy_demand)`
signature: the cost of a step depends only on `(t, u, z[t])`. -/
abbrev StageCost (H : ℕ) := Fin H → ℝ → ℝ → ℝ

/-- Total cost of a control sequence `u` on trajectory `z`. -/
def totalCost (H : ℕ) (c : StageCost H) (z : Trajectory H)
    (u : Fin H → ℝ) : ℝ :=
  ∑ t : Fin H, c t (u t) (z.z t)

/-- DP value at `s`: cost-to-go from step `s` onward, with perfect
knowledge of the realized path.  At `s = 0` this is the infimum of all
total costs. -/
noncomputable def dpValue (H : ℕ) (c : StageCost H) (z : Trajectory H)
    (s : Fin (H + 1)) : ℝ :=
  sInf { x : ℝ | ∃ u : Fin H → ℝ,
    x = ∑ t : Fin H, if (s : ℕ) ≤ (t : ℕ) then c t (u t) (z.z t) else 0 }

/-- The DP value at the start of the horizon (`s = 0`) is a lower bound
on the total cost of *every* control sequence, provided the set of
achievable total costs is bounded below (true in the EMSx setting: real
prices and physical battery limits give a finite lower bound on cost).
Perfect foresight cannot do worse than any causal (or even
non-anticipative restricted) controller.  This is the property the
experiment's upper bound uses. -/
theorem dpValue_lower_bound'
    (H : ℕ) (c : StageCost H) (z : Trajectory H) (u : Fin H → ℝ)
    (h_bdd : BddBelow { x : ℝ | ∃ u' : Fin H → ℝ, x = totalCost H c z u' }) :
    dpValue H c z ⟨0, Nat.zero_lt_succ H⟩ ≤ totalCost H c z u := by
  -- normalize: for s = 0 the conditional in dpValue is always c
  have hset_eq : { x : ℝ | ∃ u' : Fin H → ℝ,
      x = ∑ t : Fin H, if (0 : ℕ) ≤ (t : ℕ) then c t (u' t) (z.z t) else 0 }
      = { x : ℝ | ∃ u' : Fin H → ℝ, x = totalCost H c z u' } := by
    apply Set.ext
    intro x
    constructor
    · rintro ⟨u', rfl⟩
      refine ⟨u', ?_⟩
      simp [totalCost, Nat.zero_le]
    · rintro ⟨u', rfl⟩
      refine ⟨u', ?_⟩
      simp [totalCost, Nat.zero_le]
  have hdp : dpValue H c z ⟨0, Nat.zero_lt_succ H⟩ =
      sInf { x : ℝ | ∃ u' : Fin H → ℝ, x = totalCost H c z u' } := by
    dsimp [dpValue]
    -- the conditional `if 0 ≤ t then c else 0` simplifies to `c`
    congr 1
  rw [hdp]
  have hmem : totalCost H c z u ∈ { x : ℝ | ∃ u' : Fin H → ℝ, x = totalCost H c z u' } := by
    exact ⟨u, rfl⟩
  exact csInf_le h_bdd hmem

/-! ## 5. Decomposed score bounds (explicit gain ≤ upper_gain chain) -/

/-- gain ≤ upper_gain for a causal controller, restated for readability. -/
theorem score_upper_explicit (dummy model anticip : ℝ)
    (h_anticip : model ≥ anticip) (h_gain : 0 ≤ dummy - model)
    (h_upper : 0 < dummy - anticip) :
    (dummy - model) / (dummy - anticip) ≤ 1 := by
  rw [div_le_iff₀ h_upper]
  linarith

/-- score ≥ 0 for any controller improving on dummy. -/
theorem score_lower_explicit (dummy model anticip : ℝ)
    (h_gain : 0 ≤ dummy - model) (h_upper : 0 < dummy - anticip) :
    0 ≤ (dummy - model) / (dummy - anticip) := by
  positivity

end EmsxProof
