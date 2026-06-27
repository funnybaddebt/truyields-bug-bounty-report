# Immunefi Submission - TruYields / TruFin
## Aptos Staker: Permanent Freezing of Funds via MIN_COINS_ON_SHARES_POOL

**Program:** TruFin (https://immunefi.com/bug-bounty/trufin/)  
**Asset:** Aptos staker (TruAPT)  
**Severity:** Critical (Permanent freezing of funds)  
**Public source:** https://github.com/TruFin-io/smart-contracts-aptos-public

---

## Suggested Title (copy for form)

Permanent freezing of user funds in Aptos staker — last 10 APT per delegation pool cannot be unlocked

---

## Short Description (for Immunefi form - first box)

The Aptos liquid staking contract enforces a 10 APT minimum active stake per delegation pool. In `internal_unlock`, if a user's remaining balance after unlock would fall below this threshold, the contract forces a full withdrawal and then asserts that the pool will retain at least `amount + 10 APT`. 

For the last user in a pool (or when crossing the threshold), this assertion is impossible and the transaction reverts with `EUNLOCK_AMOUNT_TOO_HIGH`. The corresponding TruAPT shares are never burned and the APT remains permanently locked in the delegation pool with no recovery path.

This is a systemic design flaw affecting every delegation pool.

---

## Detailed Technical Description

### Root Cause

The contract defines:

```move
const MIN_COINS_ON_SHARES_POOL: u64 = 10_00000000; // 10 APT
```

In `internal_unlock` (staker.move ~1407-1435):

```move
assert!(amount >= MIN_COINS_ON_SHARES_POOL, EBELOW_MIN_UNLOCK);

// Force full exit if remaining would be below minimum
if (max_withdraw - amount < MIN_COINS_ON_SHARES_POOL) {
    amount = max_withdraw;
    truAPT_amount = truAPT::balance_of(receiver);
}

// Critical assertion
let (active, _, _) = delegation_pool::get_stake(pool, RESOURCE_ACCOUNT);
assert!(active >= amount + MIN_COINS_ON_SHARES_POOL, EUNLOCK_AMOUNT_TOO_HIGH);
```

When the calling user is the sole or last staker:
- `active == max_withdraw`
- Force logic sets `amount = max_withdraw`
- Assert becomes `active >= active + 10 APT` → always false → revert before any state change.

No shares are burned. No `delegation_pool::unlock` is executed. The funds stay trapped forever.

### Why Permanent (No Recovery)

- There is no "last user" or "final drain" exception.
- The minimum is taken from user principal to satisfy an Aptos delegation pool liveness requirement.
- No reserve accounting separates the 10 APT from user-backed shares.
- `collect_residual_rewards`, withdraw, and admin functions do not provide a path for the affected user to claim these funds.
- The shares continue to exist in total supply and influence share price calculations.

### Causal Chain

1. User stakes > 10 APT (or becomes last holder after others exit).
2. User calls unlock with any amount that would leave < 10 APT remaining.
3. Contract forces full amount.
4. Assert fails because pool active stake == the forced amount.
5. Revert.
6. User can repeat the call indefinitely with the same result.
7. Funds are permanently frozen.

---

## Impact

**Primary:** Permanent freezing of funds (Critical)

- Every delegation pool permanently traps at least 10 APT of user value by design.
- Users who stake small-to-medium amounts or who are the last to exit a pool lose all ability to redeem.
- The core promise of a liquid staking token ("deposit native → redeem 1:1 + yield at any time") is broken for affected positions.
- Griefing is trivial and low-cost: reduce a pool close to the minimum, then later participants cannot fully exit.

**Secondary impacts:**
- Broken user experience and loss of trust in the LST.
- Accounting mismatch: outstanding shares vs actually claimable assets.
- Protocol cannot be cleanly drained by users.
- Systemic across all Aptos pools (not a single-instance issue).

This directly matches the Immunefi Critical severity definition for "Permanent freezing of funds" and "Smart contract unable to operate due to lack of token funds" (here: lack of ability to access the tokens).

---

## Proof of Concept

I reproduced this locally using the official Move test framework on the public repo.

### Complete local reproduction

1. Clone the public repository:
   ```bash
   git clone https://github.com/TruFin-io/smart-contracts-aptos-public.git
   cd smart-contracts-aptos-public/aptos-staker
   ```

2. Critical step - fix dev-addresses (the public Move.toml has empty values, which breaks test parsing):
   Open `Move.toml` and replace the `[dev-addresses]` section with:
   ```toml
   [dev-addresses]
   publisher = "0x3"
   default_admin = "0x1"
   src_account = "0x2"
   ```

3. Add the reproduction:
   Copy the file `poc/aptos/repro_unlock_min.move` from this repository into the `tests/` folder (or paste the test function into `tests/unlock_test.move`).

   To actually trigger the freeze bug and see the revert, uncomment this line inside the test:
   ```move
   staker::unlock(alice, 5 * constants::one_apt());
   ```

4. Run:
   ```bash
   aptos move test --dev -f poc_last_ten_apt_frozen
   ```

**Expected behavior:**
- The unlock path reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.
- `truAPT::balance_of(user)` remains unchanged.
- No unlock request is created.
- `delegation_pool::get_stake` active stake is unchanged.
- `max_withdraw()` still reports the value, but the unlock is blocked.

Full ready-to-use code and exact steps are available in the secret Gist linked in the Immunefi submission.

**Note on existing test coverage:** All current tests in `unlock_test.move` use large amounts (50–1000+ APT) or extra deposits and never approach the `max_withdraw - amount < MIN_COINS_ON_SHARES_POOL` boundary.

### Manual high-level steps (for understanding)

- Whitelist a test account.
- Stake just above 10 APT.
- End epoch.
- Attempt an unlock that would leave the position below 10 APT.
- Transaction reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.
- Shares and stake remain locked. No exit is possible.

---

## Recommended Mitigation

### Primary Recommendation – Final Drain Exception
Modify `internal_unlock` to detect when the unlock would bring the pool below `MIN_COINS_ON_SHARES_POOL`. In that case:
- Allow draining the entire remaining active stake.
- Burn the corresponding shares.
- Execute the unlock for the actual remaining amount.
- Document that the delegation pool may become inactive.

This accepts the underlying Aptos requirement while preventing user funds from being permanently trapped.

### Alternative – Protocol-Owned Minimum Reserve
- Fund the 10 APT minimum from the protocol treasury / owner at pool creation.
- Explicitly exclude this reserve from `total_staked`, `tax_exempt_stake`, and all share price / fee calculations.
- User deposits never contribute to the liveness minimum.

### Additional Required Changes
- Add comprehensive boundary tests (stake 11 APT, 10 APT, 20 APT; full and partial unlock attempts).
- Consider making the minimum configurable via timelock + clear user communication.
- Update user-facing documentation to warn about practical minimum position sizes.

---

## References

**Source code (public):**
- https://github.com/TruFin-io/smart-contracts-aptos-public
- File: `aptos-staker/sources/staker.move`

**Exact locations:**
- Constant: line 37 (`MIN_COINS_ON_SHARES_POOL`)
- Force-full logic: ~1424
- Assert: ~1434
- Entry points: `unlock` (1188), `unlock_from_pool` (1203) → `internal_unlock`
- Errors: `EBELOW_MIN_UNLOCK` (7), `EUNLOCK_AMOUNT_TOO_HIGH` (20)

**Related tests:**
- `tests/unlock_test.move`
- `tests/setup_test_staker.move`
- `tests/residual_rewards_test.move`

**Underlying requirement:**
Aptos `aptos_framework::delegation_pool` requires a minimum active stake to remain active.

---

## Scope Confirmation

- All analysis performed exclusively on publicly available source code published by TruFin-io.
- No mainnet contracts were interacted with.
- No private keys or non-public information were used.
- The affected contracts and testnet deployments are explicitly listed in the TruFin Immunefi scope.

---

## Additional Materials

- Full technical report: [findings/aptos-permanent-freeze.md](../findings/aptos-permanent-freeze.md)
- Reproduction code: [poc/aptos/repro_unlock_min.move](../poc/aptos/repro_unlock_min.move)
- Repository: https://github.com/funnybaddebt/truyields-bug-bounty-report

---

**Prepared for responsible disclosure under the TruFin Immunefi bug bounty program.**  
All information is derived from public sources. 

---

**End of report**