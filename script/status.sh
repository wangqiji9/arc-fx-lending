#!/usr/bin/env bash
# 查询协议和账户状态
# 用法: ./script/status.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../deploy-keys/.env.deploy"

POOL=0x6fc50Bbd108F39Fc6B0069c29f42e4A120C9df97
USDC=0xe94C3c122204a1011EED9Ba9C11Aa8DEA861e91f
EURC=0x657ff6937aC8913AD3DbEC44430BcdeD3af1367C
WETH=0x78F1D761BC1E5D01b136e78A63AE444189ee02FB
RPC=https://rpc.testnet.arc.network

DEPLOYER=$(cast wallet address "$PRIVATE_KEY")
ALICE=$(cast wallet address "$PK_ALICE")
BOB=$(cast wallet address "$PK_BOB")
CHARLIE=$(cast wallet address "$PK_CHARLIE")

# ── helpers ──────────────────────────────────────────────────────────────────

# parse raw 3×uint256 hex → "a b c"
parse3() {
  python3 -c "
d='$1'.replace('0x','')
print(int(d[0:64],16), int(d[64:128],16), int(d[128:192],16))
"
}

# parse raw 4×uint256 hex → "a b c d"
parse4() {
  python3 -c "
d='$1'.replace('0x','')
print(int(d[0:64],16), int(d[64:128],16), int(d[128:192],16), int(d[192:256],16))
"
}

fmt6()  { python3 -c "print(f'{$1/1e6:.6f}')"; }
fmt18() { python3 -c "print(f'{$1/1e18:.6f}')"; }

wallet_bal() {
  local token=$1 account=$2
  cast call "$token" "balanceOf(address)" "$account" --rpc-url "$RPC" | python3 -c "import sys; print(int(sys.stdin.read().strip(),16))"
}

# ── 钱包余额 ─────────────────────────────────────────────────────────────────

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  钱包余额 (wallet balances)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
printf "%-10s  %14s  %14s  %14s\n" "账户" "USDC" "EURC" "WETH"
for label in "Deployer $DEPLOYER $PRIVATE_KEY" \
             "Alice    $ALICE   $PK_ALICE" \
             "Bob      $BOB     $PK_BOB" \
             "Charlie  $CHARLIE $PK_CHARLIE"; do
  name=$(echo "$label" | awk '{print $1}')
  addr=$(echo "$label" | awk '{print $2}')
  u=$(wallet_bal "$USDC" "$addr")
  e=$(wallet_bal "$EURC" "$addr")
  w=$(wallet_bal "$WETH" "$addr")
  printf "%-10s  %14s  %14s  %14s\n" "$name" "$(fmt6 $u)" "$(fmt6 $e)" "$(fmt18 $w)"
done

# ── 协议存款 ─────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  协议存款 (lender positions)"
echo "  格式: value | principal | earned"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for row in "Deployer $DEPLOYER $USDC USDC 6" \
           "Alice    $ALICE   $USDC USDC 6" \
           "Charlie  $CHARLIE $EURC EURC 6" \
           "Bob      $BOB     $WETH WETH 18"; do
  name=$(echo "$row" | awk '{print $1}')
  addr=$(echo "$row" | awk '{print $2}')
  token=$(echo "$row" | awk '{print $3}')
  sym=$(echo "$row" | awk '{print $4}')
  dec=$(echo "$row" | awk '{print $5}')
  raw=$(cast call "$POOL" "getLenderPosition(address,address)" "$token" "$addr" --rpc-url "$RPC")
  read -r val pri ear <<< "$(parse3 "$raw")"
  if [ "$val" -eq 0 ] 2>/dev/null; then
    printf "%-10s  %-6s  (无存款)\n" "$name" "$sym"
  else
    python3 -c "
d=$dec; v=$val; p=$pri; e=$ear
print(f'$name      $sym   value={v/10**d:.6f}  principal={p/10**d:.6f}  earned={e/10**d:.6f}')
"
  fi
done

# ── 借款仓位 ─────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  借款仓位 (borrow positions)"
echo "  格式: liveDebt | principal | accrued | collateral | HF"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for row in "Alice    $ALICE   $WETH  WETH  18  $USDC  USDC  6" \
           "Bob      $BOB     $USDC  USDC  6   $EURC  EURC  6" \
           "Charlie  $CHARLIE $EURC  EURC  6   $USDC  USDC  6" \
           "Deployer $DEPLOYER $WETH WETH  18  $USDC  USDC  6"; do
  name=$(echo "$row"  | awk '{print $1}')
  addr=$(echo "$row"  | awk '{print $2}')
  col=$(echo "$row"   | awk '{print $3}')
  colsym=$(echo "$row"| awk '{print $4}')
  coldec=$(echo "$row"| awk '{print $5}')
  debt=$(echo "$row"  | awk '{print $6}')
  debtsym=$(echo "$row"| awk '{print $7}')
  debtdec=$(echo "$row"| awk '{print $8}')

  key=$(cast call "$POOL" "positionKey(address,address,address)" "$addr" "$col" "$debt" --rpc-url "$RPC")
  posraw=$(cast call "$POOL" "getPosition(bytes32)" "$key" --rpc-url "$RPC")
  colamt=$(python3 -c "d='$posraw'.replace('0x',''); print(int(d[128:192],16))")
  scaled=$(python3 -c "d='$posraw'.replace('0x',''); print(int(d[192:256],16))")

  if [ "$scaled" -eq 0 ] 2>/dev/null; then
    printf "%-10s  %s/%s  (无仓位)\n" "$name" "$colsym" "$debtsym"
    continue
  fi

  biraw=$(cast call "$POOL" "getBorrowInterest(bytes32)" "$key" --rpc-url "$RPC")
  read -r livedebt pri accrued <<< "$(parse3 "$biraw")"

  hfraw=$(cast call "$POOL" "getHealthFactor(address,address,address)" "$addr" "$col" "$debt" --rpc-url "$RPC" 2>/dev/null || echo "0x0")
  hf=$(python3 -c "print(f'{int(\"$hfraw\",16)/1e18:.3f}')" 2>/dev/null || echo "?")

  python3 -c "
cd=$coldec; dd=$debtdec
print(f'$name  $colsym/$debtsym  col={$colamt/10**cd:.4f} $colsym  liveDebt={$livedebt/10**dd:.4f} $debtsym  accrued={$accrued/10**dd:.6f}  HF=$hf')
"
done

# ── 资金池 ───────────────────────────────────────────────────────────────────

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  资金池 (pool reserves)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
for row in "$USDC USDC 6" "$EURC EURC 6" "$WETH WETH 18"; do
  token=$(echo "$row" | awk '{print $1}')
  sym=$(echo "$row"   | awk '{print $2}')
  dec=$(echo "$row"   | awk '{print $3}')
  # getLiveReserveData returns (borrowIndex, liquidityIndex)
  liveraw=$(cast call "$POOL" "getLiveReserveData(address)" "$token" --rpc-url "$RPC")
  read -r bi li <<< "$(python3 -c "d='$liveraw'.replace('0x',''); print(int(d[0:64],16), int(d[64:128],16))")"
  # getReserveData for scaled totals
  resraw=$(cast call "$POOL" "getReserveData(address)" "$token" --rpc-url "$RPC")
  python3 -c "
import sys
d='$resraw'.replace('0x','')
# ReserveData: liquidityIndex(128), borrowIndex(128), totalScaledSupply(128), totalScaledBorrow(128), ...
# ABI encodes each field as 32 bytes
li   = int(d[0:64],16)
bi   = int(d[64:128],16)
tss  = int(d[128:192],16)
tsb  = int(d[192:256],16)
RAY  = 10**27
dec  = $dec
supplied = tss * li // RAY
borrowed = tsb * bi // RAY
util = borrowed * 100 // supplied if supplied > 0 else 0
print(f'$sym   supplied={supplied/10**dec:.4f}  borrowed={borrowed/10**dec:.4f}  util={util}%')
"
done
echo ""
