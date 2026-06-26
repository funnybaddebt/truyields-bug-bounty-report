# TruYields (TruFin) — Critical: Permanent Freezing of Funds

**Chain:** Aptos (TruAPT liquid staking vault)  
**Severity:** Critical  
**Category:** Permanent freezing of funds / Smart contract unable to operate

## Summary

The Aptos staker contract maintains a hard minimum of 10 APT active stake per delegation pool (`MIN_COINS_ON_SHARES_POOL = 10_00000000`).

In the unlock path, if a user's remaining position after an unlock would fall below this minimum, the contract forces a full exit of the user's entire stake. It then asserts that sufficient stake will remain to satisfy the minimum:

```move
assert!(active >= amount + MIN_COINS_ON_SHARES_POOL, EUNLOCK_AMOUNT_TOO_HIGH);
```

When the user is the last (or only) staker in the pool, or when their position crosses the threshold, this assertion always fails. The unlock reverts. The corresponding TruAPT shares are never burned and the APT remains locked in the delegation pool with no way to redeem it.

## Impact

- The final ~10 APT (plus backing shares) in every delegation pool is permanently frozen.
- Users who reduce their position near the minimum, or attempt a full exit as the last holder, lose the ability to withdraw.
- This directly violates the core promise of a liquid staking token: the ability to redeem shares for the underlying asset at any time.
- The flaw is structural and present in every pool by design.

This maps to Immunefi Critical severity ("Permanent freezing of funds").

## Details

Full technical analysis and root cause:

[findings/aptos-permanent-freeze.md](findings/aptos-permanent-freeze.md)

## Proof of Concept

A minimal reproduction is provided in the Move test framework used by the public contracts:

[poc/aptos/repro_unlock_min.move](poc/aptos/repro_unlock_min.move)

**High-level steps:**

1. Stake a small amount above the minimum (e.g. 15 APT) as a whitelisted user.
2. Attempt to unlock any amount that would leave the position below 10 APT.
3. The call reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.
4. No APT is unlocked and no unlock request is created. The shares and stake remain.

All analysis is based exclusively on the public repositories published by TruFin-io.

## References

- Public contracts: https://github.com/TruFin-io/smart-contracts-aptos-public
- Relevant code: `aptos-staker/sources/staker.move` (MIN_COINS_ON_SHARES_POOL, internal_unlock)
- In scope on Immunefi bug bounty program for TruFin.

## Mitigation

The minimum stake protection should either:
- Allow a final draining unlock that brings the pool below the threshold, or
- Treat the reserved minimum as protocol-owned (excluded from user share accounting and redeemability).

Boundary cases around this minimum should be covered in tests.