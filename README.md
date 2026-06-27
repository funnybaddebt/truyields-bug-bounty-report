# TruYields (TruFin) — Critical Finding: Permanent Freezing of Funds

**Chain:** Aptos  
**Token:** TruAPT  
**Severity:** Critical  
**Category:** Permanent freezing of funds

## Summary

The Aptos implementation of TruYields liquid staking permanently traps the last ~10 APT (plus corresponding shares) in every delegation pool.

A combination of a hard minimum stake requirement (`MIN_COINS_ON_SHARES_POOL = 10 APT`) and "force full exit" logic in `internal_unlock` causes unlock transactions to revert when a user is the last (or near-last) holder in a pool. The funds cannot be recovered.

This is a systemic flaw in the core exit path of the product.

## Impact

- Every delegation pool permanently locks at least 10 APT of user value.
- Users cannot fully exit once their position approaches the minimum.
- The fundamental redeemability guarantee of the LST is broken.
- Low-cost griefing vector exists against other users.

Full technical details, root cause, reproduction, and mitigation options are in the report below.

## Report

[findings/aptos-permanent-freeze.md](findings/aptos-permanent-freeze.md)

**Ready-to-use Immunefi submission text:**
[reports/aptos-permanent-freeze-submission.md](reports/aptos-permanent-freeze-submission.md)

## Proof of Concept

A minimal, self-contained reproduction using the official Move test framework is provided here:

[poc/aptos/repro_unlock_min.move](poc/aptos/repro_unlock_min.move)

**Complete reproduction instructions** (including the required dev-addresses fix in Move.toml) are in the ready-to-use Immunefi submission text:

[reports/aptos-permanent-freeze-submission.md](reports/aptos-permanent-freeze-submission.md)

High-level reproduction:
1. Stake an amount just above 10 APT as a whitelisted user.
2. Attempt any unlock that would leave the position below the minimum.
3. Transaction reverts with `EUNLOCK_AMOUNT_TOO_HIGH`.
4. Shares and stake remain; no exit is possible.

Full code + exact steps for reviewers are also prepared as a secret Gist for the submission.

## Scope & Sources

- Public contracts: https://github.com/TruFin-io/smart-contracts-aptos-public
- In scope per the TruFin Immunefi program (testnet stakers + public source).
- Analysis performed exclusively on publicly released code.

## Disclosure

This repository contains a focused technical report on a critical-class vulnerability in the Aptos staker. The issue was identified through direct code review and test harness analysis.