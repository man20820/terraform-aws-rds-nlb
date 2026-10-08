#!/usr/bin/env bash
#
# dr_failover_drill.sh
# ---------------------------------------------------------------------------
# Multi-AZ DR drill for the RDS MSSQL + NLB + Lambda stack.
#
# Forces an RDS Multi-AZ failover and stamps every observable event so you get
# a measured RTO instead of a guess:
#
#   T0  failover triggered (reboot --force-failover)
#   T1  RDS endpoint resolves to a NEW IP (standby promoted, DNS flipped)
#   T2  Lambda has re-registered the new IP in the NLB target group
#   T3  the new IP reports HEALTHY in the target group
#   T4  a TCP connect to the NLB on 1433 succeeds (optional, needs nc/bash tcp)
#
# RTO (data-plane recovery as seen by a client hitting the NLB) = T3 - T0.
#
# READ-ONLY except for the single reboot-with-failover call. It does NOT
# modify Terraform, security groups, or the Lambda. Safe to run repeatedly.
#
# Requirements: aws CLI v2, dig (or nslookup), bash 4+. jq optional.
# ---------------------------------------------------------------------------
set -euo pipefail

# ----------------------------- Configuration -------------------------------
# Override any of these via environment variables or edit the defaults.
REGION="${REGION:-ap-southeast-3}"
NAME_PREFIX="${NAME_PREFIX:-mssql-nlb-dev}"
DB_IDENTIFIER="${DB_IDENTIFIER:-${NAME_PREFIX}-mssql}"
TG_NAME="${TG_NAME:-${NAME_PREFIX}-mssql-tg}"
NLB_NAME="${NLB_NAME:-${NAME_PREFIX}-mssql-nlb}"
DB_PORT="${DB_PORT:-1433}"

# Lambda log group — used to confirm the updater actually fired.
LAMBDA_FN="${LAMBDA_FN:-${NAME_PREFIX}-nlb-target-updater}"

# Polling behaviour.
POLL_INTERVAL="${POLL_INTERVAL:-3}"      # seconds between checks
MAX_WAIT="${MAX_WAIT:-600}"              # give up after this many seconds
DNS_TTL_NOTE=true                        # print a reminder about DNS caching

# ----------------------------- Helpers -------------------------------------
C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
C_RED=$'\033[31m'; C_CYN=$'\033[36m'

ts()      { date -u +%Y-%m-%dT%H:%M:%SZ; }
epoch()   { date -u +%s; }
log()     { printf '%s  %s\n' "$(ts)" "$*"; }
step()    { printf '\n%s==>%s %s%s%s\n' "$C_CYN" "$C_RESET" "$C_BOLD" "$*" "$C_RESET"; }
ok()      { printf '%s[ OK ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()    { printf '%s[WARN]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()     { printf '%s[FAIL]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

need()    { command -v "$1" >/dev/null 2>&1 || die "missing required tool: $1"; }

# Resolve a hostname to its first IPv4, bypassing local caches where possible.
resolve_ip() {
  local host="$1"
  if command -v dig >/dev/null 2>&1; then
    dig +short "$host" A | grep -Eo '^[0-9.]+$' | head -n1
  else
    nslookup "$host" 2>/dev/null | awk '/^Address: /{print $2}' | tail -n1
  fi
}

aws_q() { aws --region "$REGION" "$@"; }

# ----------------------------- Preflight -----------------------------------
need aws
command -v dig >/dev/null 2>&1 || command -v nslookup >/dev/null 2>&1 \
  || die "need dig or nslookup to resolve the RDS endpoint"

step "Preflight: resolving stack resources"

ENDPOINT="$(aws_q rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
[ -n "$ENDPOINT" ] && [ "$ENDPOINT" != "None" ] || die "could not read RDS endpoint for $DB_IDENTIFIER"

read -r STATUS MULTIAZ PRIMARY_AZ SECONDARY_AZ < <(aws_q rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].[DBInstanceStatus,MultiAZ,AvailabilityZone,SecondaryAvailabilityZone]' \
  --output text)

log "Endpoint:   $ENDPOINT"
log "Status:     $STATUS"
log "Multi-AZ:   $MULTIAZ"
log "Primary AZ: $PRIMARY_AZ"
log "Standby AZ: $SECONDARY_AZ"

[ "$MULTIAZ" = "True" ] || die "instance is NOT Multi-AZ — failover will be rejected. Enable multi_az first."
[ "$STATUS" = "available" ] || die "instance status is '$STATUS', expected 'available'. Wait for the standby to finish building."

TG_ARN="$(aws_q elbv2 describe-target-groups --names "$TG_NAME" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)"
[ -n "$TG_ARN" ] && [ "$TG_ARN" != "None" ] || die "could not find target group $TG_NAME"
log "Target group: $TG_ARN"

NLB_DNS="$(aws_q elbv2 describe-load-balancers --names "$NLB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text 2>/dev/null || echo '')"
[ -n "$NLB_DNS" ] && log "NLB DNS:    $NLB_DNS" || warn "NLB DNS not resolved (name '$NLB_NAME'); T4 TCP check will be skipped"

# ----------------------------- Baseline ------------------------------------
step "Baseline capture (BEFORE failover)"

BASE_IP="$(resolve_ip "$ENDPOINT")"
[ -n "$BASE_IP" ] || die "could not resolve $ENDPOINT to an IP"
log "RDS endpoint currently resolves to: ${C_BOLD}${BASE_IP}${C_RESET}"

TG_BEFORE="$(aws_q elbv2 describe-target-health --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[].[Target.Id,TargetHealth.State]' --output text || true)"
printf 'Target group registered IP(s) / state:\n%s\n' "${TG_BEFORE:-<none>}"

if ! grep -q "$BASE_IP" <<<"$TG_BEFORE"; then
  warn "The current endpoint IP ($BASE_IP) is NOT in the target group yet."
  warn "Your Lambda sync may be lagging. Let it catch up before drilling for a clean measurement."
fi

$DNS_TTL_NOTE && warn "RDS endpoint DNS TTL is ~5s but your resolver/OS may cache longer; this script re-queries each poll."

printf '\n%sThis will FORCE a Multi-AZ failover on %s — a ~60-120s outage on a LIVE DB.%s\n' \
  "$C_YEL" "$DB_IDENTIFIER" "$C_RESET"
read -r -p "Type 'FAILOVER' to proceed: " CONFIRM
[ "$CONFIRM" = "FAILOVER" ] || die "aborted by user"

# ----------------------------- T0: trigger ---------------------------------
step "T0 — triggering failover"
T0="$(epoch)"
log "Issuing: rds reboot-db-instance --force-failover"
aws_q rds reboot-db-instance --db-instance-identifier "$DB_IDENTIFIER" --force-failover >/dev/null
ok "Failover requested at $(ts) (T0)"

# ----------------------------- T1: IP change --------------------------------
step "T1 — waiting for RDS endpoint to flip to a NEW IP"
NEW_IP=""; T1=""
while :; do
  now="$(epoch)"; (( now - T0 > MAX_WAIT )) && die "timed out waiting for endpoint IP change"
  cur="$(resolve_ip "$ENDPOINT" || true)"
  if [ -n "$cur" ] && [ "$cur" != "$BASE_IP" ]; then
    NEW_IP="$cur"; T1="$now"
    ok "Endpoint flipped: $BASE_IP -> ${C_BOLD}${NEW_IP}${C_RESET}  (T1 = +$((T1 - T0))s)"
    break
  fi
  printf '  %s still %s (+%ss)\r' "$(ts)" "${cur:-?}" "$((now - T0))"
  sleep "$POLL_INTERVAL"
done

# ----------------------------- T2: Lambda re-registers ----------------------
step "T2 — waiting for Lambda to register the new IP in the target group"
T2=""
while :; do
  now="$(epoch)"; (( now - T0 > MAX_WAIT )) && { warn "timed out waiting for TG to list new IP"; break; }
  if aws_q elbv2 describe-target-health --target-group-arn "$TG_ARN" \
       --query 'TargetHealthDescriptions[].Target.Id' --output text | grep -q "$NEW_IP"; then
    T2="$now"
    ok "New IP $NEW_IP registered in target group  (T2 = +$((T2 - T0))s)"
    break
  fi
  printf '  %s new IP not yet registered (+%ss)\r' "$(ts)" "$((now - T0))"
  sleep "$POLL_INTERVAL"
done

# ----------------------------- T3: healthy ----------------------------------
step "T3 — waiting for the new IP to report HEALTHY"
T3=""
while :; do
  now="$(epoch)"; (( now - T0 > MAX_WAIT )) && { warn "timed out waiting for HEALTHY"; break; }
  state="$(aws_q elbv2 describe-target-health --target-group-arn "$TG_ARN" \
    --query "TargetHealthDescriptions[?Target.Id=='$NEW_IP'].TargetHealth.State" --output text || true)"
  if [ "$state" = "healthy" ]; then
    T3="$now"
    ok "New IP $NEW_IP is HEALTHY  (T3 = +$((T3 - T0))s)"
    break
  fi
  printf '  %s state=%s (+%ss)\r' "$(ts)" "${state:-?}" "$((now - T0))"
  sleep "$POLL_INTERVAL"
done

# ----------------------------- T4: TCP connect through NLB ------------------
# T4 is OPTIONAL. For an INTERNAL NLB (private subnets) it is unreachable from a
# drill host outside the VPC, so it is skipped by default. T3 (target healthy)
# is the RTO endpoint. To run T4, invoke with SKIP_T4=no from a host inside the
# VPC (bastion/EC2/CloudShell-in-VPC).
T4=""
SKIP_T4="${SKIP_T4:-yes}"
if [ "$SKIP_T4" = "yes" ]; then
  warn "T4 skipped (SKIP_T4=yes): internal NLB not reachable from this host. RTO is measured to T3 (target healthy)."
elif [ -n "$NLB_DNS" ]; then
  step "T4 — confirming TCP connect to NLB:$DB_PORT succeeds"
  while :; do
    now="$(epoch)"; (( now - T0 > MAX_WAIT )) && { warn "timed out on NLB TCP connect"; break; }
    if timeout 3 bash -c "echo > /dev/tcp/$NLB_DNS/$DB_PORT" 2>/dev/null; then
      T4="$now"
      ok "TCP connect to $NLB_DNS:$DB_PORT OK  (T4 = +$((T4 - T0))s)"
      break
    fi
    printf '  %s NLB:%s not accepting yet (+%ss)\r' "$(ts)" "$DB_PORT" "$((now - T0))"
    sleep "$POLL_INTERVAL"
  done
fi

# ----------------------------- Lambda confirmation --------------------------
step "Lambda invocation evidence (CloudWatch Logs, last 10 min)"
START_MS=$(( (T0 - 60) * 1000 ))
if aws_q logs filter-log-events \
     --log-group-name "/aws/lambda/$LAMBDA_FN" \
     --start-time "$START_MS" \
     --filter-pattern 'updated' \
     --query 'events[].message' --output text 2>/dev/null | grep -q .; then
  aws_q logs filter-log-events \
    --log-group-name "/aws/lambda/$LAMBDA_FN" \
    --start-time "$START_MS" \
    --filter-pattern 'updated' \
    --query 'events[-3:].message' --output text 2>/dev/null | sed 's/^/    /'
  ok "Lambda logged an 'updated' event (confirms it drove the re-registration)"
else
  warn "No 'updated' Lambda log found yet — the periodic 5-min sync may have beaten the event, or logs lag. Check /aws/lambda/$LAMBDA_FN."
fi

# ----------------------------- Post-failover AZ state -----------------------
step "Post-failover AZ roles"
read -r NEW_PRIMARY NEW_SECONDARY < <(aws_q rds describe-db-instances \
  --db-instance-identifier "$DB_IDENTIFIER" \
  --query 'DBInstances[0].[AvailabilityZone,SecondaryAvailabilityZone]' --output text)
log "Primary AZ: $PRIMARY_AZ -> ${C_BOLD}${NEW_PRIMARY}${C_RESET}"
log "Standby AZ: $SECONDARY_AZ -> ${C_BOLD}${NEW_SECONDARY}${C_RESET}"
[ "$NEW_PRIMARY" != "$PRIMARY_AZ" ] && ok "AZ roles flipped — failover confirmed at the DB layer." \
  || warn "Primary AZ unchanged; double-check the failover actually occurred."

# ----------------------------- Summary --------------------------------------
step "DR DRILL SUMMARY"
fmt() { [ -n "$1" ] && printf '+%ss' "$(( $1 - T0 ))" || printf '%s' "n/a (timed out)"; }
printf '%s\n' "-------------------------------------------------------------"
printf '  T0  failover triggered        %s\n' "$(ts)"
printf '  T1  endpoint IP changed        %s\n' "$(fmt "$T1")"
printf '  T2  new IP in target group     %s\n' "$(fmt "$T2")"
printf '  T3  new IP HEALTHY             %s\n' "$(fmt "$T3")"
if [ "$SKIP_T4" = "yes" ]; then
  printf '  T4  NLB TCP connect            skipped (internal NLB)\n'
elif [ -n "$NLB_DNS" ]; then
  printf '  T4  NLB TCP connect OK         %s\n' "$(fmt "$T4")"
fi
printf '%s\n' "-------------------------------------------------------------"
if [ -n "$T3" ]; then
  printf '  %sMEASURED RTO (client-visible, T3 - T0): %ss%s\n' "$C_BOLD" "$((T3 - T0))" "$C_RESET"
else
  printf '  %sRTO: NOT REACHED within %ss — investigate the gap above.%s\n' "$C_RED" "$MAX_WAIT" "$C_RESET"
fi
printf '%s\n' "-------------------------------------------------------------"
printf '  Old IP: %s   New IP: %s\n' "$BASE_IP" "${NEW_IP:-?}"
printf '  Note: RPO for Multi-AZ synchronous replication is ~0 (no committed data loss).\n'
printf '  Note: T2-T0 is dominated by your EventBridge/5-min sync lag. For prod,\n'
printf '        consider rate(1 minute) on the periodic-sync rule in lambda_nlb_updater.tf.\n'
