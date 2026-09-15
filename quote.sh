#!/usr/bin/env bash
# Probe the public Loop swap servers for limits and fees. Needs no node and no
# L402 token: LoopInTerms/LoopInQuote/LoopOutTerms/LoopOutQuote sit behind
# aperture's auth whitelist.
set -euo pipefail

NETWORK="${1:-mainnet}"
PROTO_REF="${LOOP_PROTO_REF:-master}"
USER_AGENT="loopd/v0.35.0-beta"
PROTOCOL_VERSION="MUSIG2"
AMOUNTS=(250000 500000 1000000 5000000 10000000 50000000 240000000)

case "$NETWORK" in
  mainnet) SERVER="swap.lightning.today:11010" ;;
  testnet) SERVER="test.swap.lightning.today:11010" ;;
  signet)  SERVER="signet.swap.lightning.today:11010" ;;
  *) echo "usage: $0 [mainnet|testnet|signet]" >&2; exit 2 ;;
esac

command -v grpcurl >/dev/null || { echo "grpcurl missing: brew install grpcurl" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq missing: brew install jq" >&2; exit 1; }

PROTO_DIR="$(cd "$(dirname "$0")" && pwd)/.protos/swapserverrpc"
if [ ! -f "$PROTO_DIR/server.proto" ]; then
  mkdir -p "$PROTO_DIR"
  for f in common server instantout reservation staticaddr; do
    curl -fsSL -o "$PROTO_DIR/$f.proto" \
      "https://raw.githubusercontent.com/lightninglabs/loop/$PROTO_REF/swapserverrpc/$f.proto"
  done
fi

call() {
  grpcurl -max-time 20 -import-path "$PROTO_DIR" -proto server.proto \
    -d "$2" "$SERVER" "looprpc.SwapServer/$1"
}

base_args() { echo "\"protocol_version\":\"$PROTOCOL_VERSION\",\"user_agent\":\"$USER_AGENT\""; }

# Loop Out needs an absolute expiry height inside [min_cltv_delta, max_cltv_delta].
tip_height() {
  case "$NETWORK" in
    mainnet) curl -fsS https://mempool.space/api/blocks/tip/height ;;
    testnet) curl -fsS https://mempool.space/testnet/api/blocks/tip/height ;;
    signet)  curl -fsS https://mempool.space/signet/api/blocks/tip/height ;;
  esac
}

fmt_pct() { python3 -c "import sys;f,a=int(sys.argv[1]),int(sys.argv[2]);print(f'{f/a*100:.4f}%')" "$1" "$2"; }

echo "# Loop server: $NETWORK ($SERVER)"
echo "# probed $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo

IN_TERMS=$(call LoopInTerms "{$(base_args)}")
OUT_TERMS=$(call LoopOutTerms "{$(base_args)}")

echo "## Limits"
printf '%-12s %-14s %-14s\n' "DIRECTION" "MIN_SAT" "MAX_SAT"
printf '%-12s %-14s %-14s\n' "loop in"  "$(jq -r .minSwapAmount <<<"$IN_TERMS")"  "$(jq -r .maxSwapAmount <<<"$IN_TERMS")"
printf '%-12s %-14s %-14s\n' "loop out" "$(jq -r .minSwapAmount <<<"$OUT_TERMS")" "$(jq -r .maxSwapAmount <<<"$OUT_TERMS")"
echo "loop out cltv delta: $(jq -r .minCltvDelta <<<"$OUT_TERMS") to $(jq -r .maxCltvDelta <<<"$OUT_TERMS")"
echo

echo "## Loop In (we receive on chain)"
printf '%-12s %-10s %-10s %s\n' "AMOUNT" "SWAP_FEE" "PCT" "CLTV"
for amt in "${AMOUNTS[@]}"; do
  r=$(call LoopInQuote "{\"amt\":$amt,$(base_args)}" 2>/dev/null) || { echo "$amt  <rejected>"; continue; }
  fee=$(jq -r '.swapFee // empty' <<<"$r")
  [ -n "$fee" ] || { echo "$amt  <rejected>"; continue; }
  printf '%-12s %-10s %-10s %s\n' "$amt" "$fee" "$(fmt_pct "$fee" "$amt")" "$(jq -r '.cltvDelta // "-"' <<<"$r")"
done
echo

HEIGHT=$(tip_height)
EXPIRY=$((HEIGHT + 200))
DEADLINE=$(python3 -c "import time;print(int((time.time()+1800)*1e9))")

echo "## Loop Out (we send on chain), tip=$HEIGHT expiry=$EXPIRY"
printf '%-12s %-10s %-10s %s\n' "AMOUNT" "SWAP_FEE" "PCT" "PREPAY"
for amt in "${AMOUNTS[@]}"; do
  r=$(call LoopOutQuote "{\"amt\":$amt,\"swap_publication_deadline\":$DEADLINE,\"expiry\":$EXPIRY,$(base_args)}" 2>/dev/null) || { echo "$amt  <rejected>"; continue; }
  fee=$(jq -r '.swapFee // empty' <<<"$r")
  [ -n "$fee" ] || { echo "$amt  <rejected>"; continue; }
  printf '%-12s %-10s %-10s %s\n' "$amt" "$fee" "$(fmt_pct "$fee" "$amt")" "$(jq -r '.prepayAmt // "-"' <<<"$r")"
done
