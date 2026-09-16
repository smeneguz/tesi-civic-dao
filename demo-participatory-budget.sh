#!/usr/bin/env bash
#
# demo-participatory-budget.sh
#
# Narrated, end-to-end demo of the CivicDAO public flow (participatory
# budgeting with Quadratic Voting) run against a real local Anvil node.
#
# Self-contained: it deploys CitizenshipSBT AND ParticipatoryBudget itself,
# onboards 5 citizens through the real mintWithAuth flow, then runs a full
# voting round from opening to the Municipality's recorded outcome.
# (demo-onboarding.sh is a separate, standalone demo of onboarding alone --
# this script does not depend on it and repeats the onboarding step itself,
# more tersely, only as a prerequisite to reach the electorate this demo needs.)
#
# What this proves, with real on-chain transactions (not mocks):
#   1. Citizens are onboarded via the real EIP-712 mintWithAuth flow (the
#      Comune signs off-chain with account #0's key). The nullifier is a
#      keyed commitment to each citizen's codice fiscale -- keccak(codice
#      fiscale || MUNICIPALITY_SECRET) -- not to their wallet address, so
#      Sybil-resistance is per REAL PERSON, not per address (a citizen
#      cannot obtain two SBTs by minting from two different wallets).
#      Exactly like the on-chain identity layer described in the thesis
#      (sez. 5.4).
#   2. The Municipality (account #0, MUNICIPALITY_ROLE) opens a round over a
#      fixed 3-proposal slate with a 100-credit Quadratic Voting budget.
#   3. Five citizens cast one ballot each: one spends everything on a single
#      proposal (10 votes = 100 credits, the QV maximum concentration),
#      others spread their budget across several proposals. Each ballot's
#      quadratic cost is narrated as it's paid.
#   4. The round is closed once its window elapses. Because this runs against
#      a LIVE Anvil node, vm.warp has no effect here -- only Anvil's own
#      evm_increaseTime + evm_mine RPC methods actually move the chain's
#      clock, so that's what this script uses (combined with a short voting
#      window) to reach the deadline deterministically and instantly, with
#      no reliance on wall-clock sleeps.
#   5. Final scores, the winner and the quorum outcome are read back on-chain
#      and printed as a table.
#   6. The Municipality records the outcome. As a counter-proof, it first
#      attempts to mark the winning proposal NotExecuted WITHOUT a reasons
#      CID (must revert: ReasonsRequired), then does it correctly, showing
#      the duty to give reasons is enforced on-chain, not just a convention.
#
# Usage: ./demo-participatory-budget.sh   (single command; starts and stops Anvil itself)
#
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

# ---------------------------------------------------------------------------
# Terminal narration helpers
# ---------------------------------------------------------------------------
BOLD=$'\033[1m'; RESET=$'\033[0m'
RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; CYAN=$'\033[36m'; MAGENTA=$'\033[35m'

# All narration goes to stderr on purpose: several helper functions below are
# called as `x=$(some_function ...)` to capture an actual return value (an
# address, a digest, a signature, a score) on stdout. If narration printed to
# stdout too, it would end up swallowed into that captured value instead of
# being shown on screen.
# Pause before every section header so the presenter can advance one phase at
# a time by pressing Enter (instead of the whole demo running unattended).
# Reads from the controlling terminal (/dev/tty) rather than plain stdin, so
# this still works even if the script's own stdin is redirected. If no
# terminal is available at all (e.g. running under CI with output piped to a
# file), it degrades gracefully by skipping the pause instead of hanging.
pause_for_next_phase() {
    if [ -t 0 ] || [ -r /dev/tty ]; then
        printf "\n  ${YELLOW}...${RESET} Press Enter to continue" >&2
        read -r _ < /dev/tty 2>/dev/null || read -r _
    fi
}

section() { pause_for_next_phase; printf "\n${BOLD}${CYAN}== %s ==${RESET}\n" "$1" >&2; }
info()    { printf "  %s\n" "$1" >&2; }
ok()      { printf "  ${GREEN}OK${RESET}  %s\n" "$1" >&2; }
warn()    { printf "  ${YELLOW}!${RESET}   %s\n" "$1" >&2; }
ballot()  { printf "  ${MAGENTA}ballot${RESET} %s\n" "$1" >&2; }

# Shorten a long 0x-hex string for readable narration (e.g. 0x1234ab...cd5678).
short() { local s="$1"; printf "%s...%s" "${s:0:10}" "${s: -6}"; }

die() {
    # %b (not %s) so a literal \n in the message (used by callers to append
    # multi-line command output) renders as an actual line break.
    printf "\n${RED}${BOLD}UNEXPECTED ERROR${RESET}: %b\n" "$1" >&2
    exit 1
}

# ---------------------------------------------------------------------------
# Anvil lifecycle (single command: start in background, stop on exit)
# ---------------------------------------------------------------------------
RPC="http://127.0.0.1:8545"
ANVIL_LOG="$(mktemp -t anvil-pb-demo-XXXXXX.log)"
DEPLOY_ERR="$(mktemp -t deploy-pb-demo-XXXXXX.err)"
ANVIL_PID=""

cleanup() {
    if [ -n "$ANVIL_PID" ] && kill -0 "$ANVIL_PID" 2>/dev/null; then
        section "Shutdown"
        info "Stopping the Anvil node (pid $ANVIL_PID)..."
        kill "$ANVIL_PID" 2>/dev/null
        wait "$ANVIL_PID" 2>/dev/null
        ok "Anvil stopped. Full log: $ANVIL_LOG"
    fi
}
trap cleanup EXIT INT TERM

section "Starting the local node"
info "Launching Anvil on $RPC (full log: $ANVIL_LOG)..."
anvil --port 8545 >"$ANVIL_LOG" 2>&1 &
ANVIL_PID=$!

READY=0
for _ in $(seq 1 30); do
    if cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then READY=1; break; fi
    sleep 0.3
done
[ "$READY" = "1" ] || die "Anvil is not responding on $RPC after 9s. Check $ANVIL_LOG."
ok "Anvil ready (chain id $(cast chain-id --rpc-url "$RPC"))."

# ---------------------------------------------------------------------------
# Anvil's well-known default dev accounts (mnemonic "test test ... junk").
# Public, fixed, and meant only for local development -- never use these
# keys anywhere but a throwaway local chain like this one.
# ---------------------------------------------------------------------------
ADDR_COMUNE=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
PK_COMUNE=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80

ADDR_ALICE=0x70997970C51812dc3A010C7d01b50e0d17dc79C8
PK_ALICE=0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d

ADDR_BOB=0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC
PK_BOB=0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a

ADDR_CAROL=0x90F79bf6EB2c4f870365E785982E1f101E93b906
PK_CAROL=0x7c852118294e51e653712a81e05800f419141751be58f605c371e15141b007a6

ADDR_DAVE=0x15d34AAf54267DB7D7c367839AAf71A00a2C6A65
PK_DAVE=0x47e179ec197488593b187f80a00eb0da91f1b9d0b13f8733639f19c30a34926a

ADDR_ELENA=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
PK_ELENA=0x8b3a350cf5c34c9194ca85829a2df0ec3153be0318b5e2d3348e872092edffba

# ---------------------------------------------------------------------------
# Fictional codici fiscali (demo data, not real people) and the Comune's
# nullifier secret. The nullifier is now a keyed commitment to the PERSON
# (codice fiscale), not to the wallet address: nullifier =
# keccak(codiceFiscale || MUNICIPALITY_SECRET). Keying it with a secret only
# the Comune knows matters because a codice fiscale is NOT itself secret --
# it's publicly derivable from name + birth date/place -- so without the
# secret anyone could precompute a target person's nullifier and probe the
# public nullifierUsed mapping to learn whether they're already a citizen.
# In production MUNICIPALITY_SECRET would live in an HSM/KMS, be rotated,
# and be shared consistently across every ISSUER_ROLE operator; here it's a
# hardcoded demo string, exactly like the private keys above.
# ---------------------------------------------------------------------------
MUNICIPALITY_SECRET="comune-segreto-demo-non-usare-in-produzione"

CF_ALICE="LCAALC85A41H501K"
CF_BOB="BOBRRT82B15H501J"
CF_CAROL="CRLCRL90C58H501Y"
CF_DAVE="DVAADV79D22H501B"
CF_ELENA="LNEELN95E60H501P"

section "Demo actors (Anvil default accounts)"
info "Comune (deployer, ISSUER_ROLE + MUNICIPALITY_ROLE)  = $ADDR_COMUNE"
info "Alice  (citizen, account #1)                        = $ADDR_ALICE"
info "Bob    (citizen, account #2)                        = $ADDR_BOB"
info "Carol  (citizen, account #3)                        = $ADDR_CAROL"
info "Dave   (citizen, account #4)                        = $ADDR_DAVE"
info "Elena  (citizen, account #5)                        = $ADDR_ELENA"

# ---------------------------------------------------------------------------
# Prerequisite (assumed, not narrated): a deployed CitizenshipSBT with the 5
# citizens already onboarded. This demo is about the participatory-budget
# flow, not about onboarding -- that flow (the real EIP-712 mintWithAuth
# signature, nullifiers, soulbound checks) is the whole subject of
# demo-onboarding.sh and is narrated there step by step. Here it is only
# provisioned quietly, with the same real transactions but no play-by-play.
# ---------------------------------------------------------------------------
section "Electorate setup (assumed done)"

SBT_JSON=$(forge create src/CitizenshipSBT.sol:CitizenshipSBT \
    --rpc-url "$RPC" --private-key "$PK_COMUNE" --broadcast --json \
    --constructor-args "$ADDR_COMUNE" "$ADDR_COMUNE" 2>"$DEPLOY_ERR") \
    || die "CitizenshipSBT deployment failed: $(cat "$DEPLOY_ERR")"
SBT=$(echo "$SBT_JSON" | grep -oE '"deployedTo": *"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')
[ -n "$SBT" ] || die "Could not read the CitizenshipSBT address from: $SBT_JSON"

PB_JSON=$(forge create src/ParticipatoryBudget.sol:ParticipatoryBudget \
    --rpc-url "$RPC" --private-key "$PK_COMUNE" --broadcast --json \
    --constructor-args "$SBT" "$ADDR_COMUNE" 2>"$DEPLOY_ERR") \
    || die "ParticipatoryBudget deployment failed: $(cat "$DEPLOY_ERR")"
PB=$(echo "$PB_JSON" | grep -oE '"deployedTo": *"0x[0-9a-fA-F]+"' | grep -oE '0x[0-9a-fA-F]+')
[ -n "$PB" ] || die "Could not read the ParticipatoryBudget address from: $PB_JSON"

# Real mintWithAuth calls (EIP-712 signature by the Comune) -- same flow as
# demo-onboarding.sh, just without its narration. The nullifier is computed
# by the Comune from the citizen's codice fiscale + MUNICIPALITY_SECRET (see
# the note above), not from their wallet address: anti-Sybil per person.
onboard() {
    local addr="$1" pk="$2" cf="$3"
    local nullifier deadline digest sig out
    nullifier=$(cast keccak "$cf:$MUNICIPALITY_SECRET")
    deadline=$(( $(date +%s) + 3600 ))
    digest=$(cast call "$SBT" "hashMintAuth(address,bytes32,uint256)(bytes32)" \
        "$addr" "$nullifier" "$deadline" --rpc-url "$RPC") \
        || die "on-chain hashMintAuth() failed for $addr"
    sig=$(cast wallet sign --no-hash --private-key "$PK_COMUNE" "$digest")
    out=$(cast send "$SBT" "mintWithAuth(address,bytes32,uint256,bytes)" \
        "$addr" "$nullifier" "$deadline" "$sig" \
        --private-key "$pk" --rpc-url "$RPC" 2>&1) \
        || die "$addr: mintWithAuth should have succeeded but failed:\n$out"
}

onboard "$ADDR_ALICE" "$PK_ALICE" "$CF_ALICE"
onboard "$ADDR_BOB"   "$PK_BOB"   "$CF_BOB"
onboard "$ADDR_CAROL" "$PK_CAROL" "$CF_CAROL"
onboard "$ADDR_DAVE"  "$PK_DAVE"  "$CF_DAVE"
onboard "$ADDR_ELENA" "$PK_ELENA" "$CF_ELENA"

ELECTORATE=$(cast call "$SBT" "totalSupply()(uint256)" --rpc-url "$RPC")
ok "CitizenshipSBT: $SBT  |  ParticipatoryBudget: $PB"
ok "Electorate ready: $ELECTORATE citizens onboarded (Alice, Bob, Carol, Dave, Elena)"

# ---------------------------------------------------------------------------
# Open the round: 3 proposals, 100 QV credits per voter, short window (the
# window only needs to be long enough for the votes below to be sent; it is
# then skipped past with Anvil's own clock, see the closing section).
# ---------------------------------------------------------------------------
section "Opening the participatory budget round"

LABEL_P0="Accessible, inclusive playground"
LABEL_P1="Public Wi-Fi network in the square"
LABEL_P2="Shared urban garden"
CID_P0="ipfs://bafybei-demo-playground-0001"
CID_P1="ipfs://bafybei-demo-public-wifi-0002"
CID_P2="ipfs://bafybei-demo-urban-garden-0003"
CREDITS=100
DURATION=30 # seconds; short on purpose, see the note above evm_increaseTime below

info "Fundable proposals (slate fixed by the Comune):"
info "  P0: $LABEL_P0  ($CID_P0)"
info "  P1: $LABEL_P1  ($CID_P1)"
info "  P2: $LABEL_P2  ($CID_P2)"
info "QV credits per citizen: $CREDITS  |  voting duration: ${DURATION}s"

OUT=$(cast send "$PB" "openRound(uint256,string[],uint64)" \
    "$CREDITS" "[\"$CID_P0\",\"$CID_P1\",\"$CID_P2\"]" "$DURATION" \
    --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1) \
    || die "openRound failed:\n$OUT"
ROUND_ID=0 # first round opened on a fresh chain
ok "Round #$ROUND_ID opened by the Comune. Electorate snapshot recorded: $ELECTORATE"

# ---------------------------------------------------------------------------
# Casting ballots. Quadratic Voting: spending v votes on a proposal costs
# v^2 credits out of the 100-credit budget. proposalIds must be passed in
# strictly increasing order.
# ---------------------------------------------------------------------------
section "Voting (Quadratic Voting, 100-credit budget each)"

cast_vote() {
    local name="$1" pk="$2" ids_json="$3" votes_json="$4" narration="$5"
    ballot "$name -> $narration"
    local out
    out=$(cast send "$PB" "castVotes(uint256,uint256[],uint256[])" \
        "$ROUND_ID" "$ids_json" "$votes_json" \
        --private-key "$pk" --rpc-url "$RPC" 2>&1) \
        || die "$name: castVotes should have succeeded but failed:\n$out"
}

# Alice concentrates her entire budget on P0: the QV maximum, 10 votes on a
# single proposal, sqrt(100) = 10, costing exactly 10^2 = 100 credits.
cast_vote "Alice" "$PK_ALICE" "[0]" "[10]" \
    "10 votes all on P0 (maximum concentration: 10^2 = 100 credits)"

# Bob spreads his budget across all three proposals.
cast_vote "Bob" "$PK_BOB" "[0,1,2]" "[6,5,6]" \
    "6 on P0 + 5 on P1 + 6 on P2 (36+25+36 = 97 credits)"

# Carol spreads across two proposals.
cast_vote "Carol" "$PK_CAROL" "[1,2]" "[7,7]" \
    "7 on P1 + 7 on P2 (49+49 = 98 credits)"

# Dave spreads across two proposals, favoring P0.
cast_vote "Dave" "$PK_DAVE" "[0,1]" "[8,4]" \
    "8 on P0 + 4 on P1 (64+16 = 80 credits)"

# Elena casts a modest single-proposal ballot.
cast_vote "Elena" "$PK_ELENA" "[2]" "[5]" \
    "5 on P2 (25 credits)"

ok "5 out of $ELECTORATE citizens have voted."

# ---------------------------------------------------------------------------
# Close the round. IMPORTANT: this runs against a LIVE Anvil node, so
# vm.warp (a Forge-test-only cheatcode) has no effect on it whatsoever --
# only Anvil's own JSON-RPC methods actually move the chain's clock. We
# advance time past the voting deadline with evm_increaseTime, then mine a
# block with evm_mine so the new timestamp is actually committed on-chain.
# This is deterministic and instant: no wall-clock sleeping involved.
# ---------------------------------------------------------------------------
section "Passing the deadline and closing the round"
info "Using evm_increaseTime + evm_mine to advance the chain's clock..."
cast rpc evm_increaseTime $((DURATION + 5)) --rpc-url "$RPC" >/dev/null \
    || die "evm_increaseTime failed"
cast rpc evm_mine --rpc-url "$RPC" >/dev/null \
    || die "evm_mine failed"
ok "Chain clock advanced by $((DURATION + 5))s past the voting window."

OUT=$(cast send "$PB" "closeRound(uint256)" "$ROUND_ID" --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1) \
    || die "closeRound failed:\n$OUT"
ok "Round #$ROUND_ID closed."

# ---------------------------------------------------------------------------
# Results table.
# ---------------------------------------------------------------------------
section "Results"

SCORE_P0=$(cast call "$PB" "getScore(uint256,uint256)(uint256)" "$ROUND_ID" 0 --rpc-url "$RPC")
SCORE_P1=$(cast call "$PB" "getScore(uint256,uint256)(uint256)" "$ROUND_ID" 1 --rpc-url "$RPC")
SCORE_P2=$(cast call "$PB" "getScore(uint256,uint256)(uint256)" "$ROUND_ID" 2 --rpc-url "$RPC")

# getRound() returns the Round struct as a flat tuple; field 7 (0-indexed) is
# quorumReached, field 4 is voterCount.
mapfile -t ROUND_FIELDS < <(cast call "$PB" \
    "getRound(uint256)(uint256,uint64,uint64,uint256,uint256,uint256,uint8,bool)" \
    "$ROUND_ID" --rpc-url "$RPC")
VOTER_COUNT="${ROUND_FIELDS[4]}"
QUORUM_REACHED="${ROUND_FIELDS[7]}"

printf "\n  %-6s %-38s %s\n" "ID" "Proposal" "Score" >&2
printf "  %-6s %-38s %s\n" "--" "--------" "-----" >&2
printf "  %-6s %-38s %s\n" "P0" "$LABEL_P0" "$SCORE_P0" >&2
printf "  %-6s %-38s %s\n" "P1" "$LABEL_P1" "$SCORE_P1" >&2
printf "  %-6s %-38s %s\n" "P2" "$LABEL_P2" "$SCORE_P2" >&2

# Determine the winner from the actual on-chain scores (not hardcoded).
WINNER_ID=0; WINNER_SCORE=$SCORE_P0; WINNER_LABEL="$LABEL_P0"
if [ "$SCORE_P1" -gt "$WINNER_SCORE" ]; then WINNER_ID=1; WINNER_SCORE=$SCORE_P1; WINNER_LABEL="$LABEL_P1"; fi
if [ "$SCORE_P2" -gt "$WINNER_SCORE" ]; then WINNER_ID=2; WINNER_SCORE=$SCORE_P2; WINNER_LABEL="$LABEL_P2"; fi

info ""
info "${BOLD}Winner: P$WINNER_ID -- $WINNER_LABEL${RESET} (score $WINNER_SCORE)"
info "Voters: $VOTER_COUNT out of an electorate of $ELECTORATE (quorum required: 10%)."
if [ "$QUORUM_REACHED" = "true" ]; then
    ok "Quorum reached (quorumReached = true)."
else
    warn "Quorum NOT reached (quorumReached = false)."
fi

# ---------------------------------------------------------------------------
# Municipality records the outcome: the codified duty to give reasons.
# Counter-proof FIRST: attempt to record NotExecuted on the winning proposal
# WITHOUT a reasons CID -- must revert with ReasonsRequired. Then do it
# properly, with the CID, which must succeed.
# ---------------------------------------------------------------------------
section "Recording the outcome (the Municipality's duty to give reasons)"

info "Counter-proof: the Comune tries to record NotExecuted on P$WINNER_ID WITHOUT a reasonsCid..."
if OUT=$(cast send "$PB" "recordOutcome(uint256,uint256,uint8,string)" \
    "$ROUND_ID" "$WINNER_ID" 2 "" --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1); then
    die "The call without a reasonsCid should have reverted but went through"
fi
if echo "$OUT" | grep -q "ReasonsRequired"; then
    ok "Revert confirmed (ReasonsRequired): without written reasons, NotExecuted is blocked on-chain."
else
    die "Reverted, but with an unexpected error (expected ReasonsRequired):\n$OUT"
fi

REASONS_CID="ipfs://reasons"
info "Now the Comune records the same outcome WITH the reasons ($REASONS_CID)..."
OUT=$(cast send "$PB" "recordOutcome(uint256,uint256,uint8,string)" \
    "$ROUND_ID" "$WINNER_ID" 2 "$REASONS_CID" --private-key "$PK_COMUNE" --rpc-url "$RPC" 2>&1) \
    || die "recordOutcome with a reasonsCid should have succeeded but failed:\n$OUT"
ok "Outcome recorded on-chain: P$WINNER_ID -> NotExecuted, reasonsCid = $REASONS_CID"
info "The justification (its IPFS CID) is now a permanent, immutable part of the"
info "on-chain state: the Comune can depart from the community's vote, but not"
info "without leaving a public, attributable (MUNICIPALITY_ROLE) trace of why."

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
section "Summary"
info "CitizenshipSBT:      $SBT"
info "ParticipatoryBudget: $PB"
info "Onboarded electorate: $ELECTORATE citizens (Alice, Bob, Carol, Dave, Elena)"
info "Round #$ROUND_ID: winner P$WINNER_ID ($WINNER_LABEL, score $WINNER_SCORE), quorum=$QUORUM_REACHED"
info "Outcome recorded: NotExecuted with an on-chain reason ($REASONS_CID)"
printf "\n${BOLD}${GREEN}Demo completed successfully.${RESET}\n"
