/**
 * Lambda function to update NLB target group IP when RDS failover occurs.
 *
 * Triggered by EventBridge on RDS failover events and periodic schedule.
 * Resolves the RDS endpoint DNS to get the current IP, deregisters stale
 * targets, and registers the new IP in the NLB target group.
 */

import dns from "node:dns/promises";
import {
  ElasticLoadBalancingV2Client,
  DescribeTargetHealthCommand,
  DeregisterTargetsCommand,
  RegisterTargetsCommand,
} from "@aws-sdk/client-elastic-load-balancing-v2";

const elbv2 = new ElasticLoadBalancingV2Client({});

const TARGET_GROUP_ARN = process.env.TARGET_GROUP_ARN;
const RDS_ENDPOINT = process.env.RDS_ENDPOINT;
const RDS_PORT = parseInt(process.env.RDS_PORT ?? "1433", 10);

/**
 * Resolve hostname to IPv4 address.
 * @param {string} hostname
 * @returns {Promise<string>}
 */
async function resolveIp(hostname) {
  const addresses = await dns.resolve4(hostname);
  if (!addresses || addresses.length === 0) {
    throw new Error(`Could not resolve hostname: ${hostname}`);
  }
  const ip = addresses[0];
  console.log(`Resolved ${hostname} -> ${ip}`);
  return ip;
}

/**
 * Get currently registered targets in the target group.
 * @returns {Promise<Array<{Id: string, Port: number}>>}
 */
async function getRegisteredTargets() {
  const response = await elbv2.send(
    new DescribeTargetHealthCommand({ TargetGroupArn: TARGET_GROUP_ARN })
  );
  const targets = response.TargetHealthDescriptions.map((t) => t.Target);
  console.log("Current targets:", JSON.stringify(targets));
  return targets;
}

/**
 * Deregister a list of targets from the target group.
 * @param {Array<{Id: string, Port: number}>} targets
 */
async function deregisterTargets(targets) {
  if (targets.length === 0) return;
  console.log("Deregistering targets:", JSON.stringify(targets));
  await elbv2.send(
    new DeregisterTargetsCommand({
      TargetGroupArn: TARGET_GROUP_ARN,
      Targets: targets,
    })
  );
}

/**
 * Register a new IP target in the target group.
 * @param {string} ip
 * @param {number} port
 */
async function registerTarget(ip, port) {
  const target = { Id: ip, Port: port };
  console.log("Registering target:", JSON.stringify(target));
  await elbv2.send(
    new RegisterTargetsCommand({
      TargetGroupArn: TARGET_GROUP_ARN,
      Targets: [target],
    })
  );
}

/**
 * Lambda handler.
 *
 * Accepts both EventBridge RDS failover events and manual invocations
 * (e.g. for initial bootstrap or forced refresh).
 *
 * @param {object} event
 * @returns {Promise<{status: string, ip?: string, old_ips?: string[], new_ip?: string}>}
 */
export async function handler(event) {
  console.log("Event received:", JSON.stringify(event));

  // Resolve current RDS IP
  const newIp = await resolveIp(RDS_ENDPOINT);

  // Get existing targets
  const currentTargets = await getRegisteredTargets();
  const currentIps = new Set(currentTargets.map((t) => t.Id));

  // Check if already up to date
  if (currentIps.size === 1 && currentIps.has(newIp)) {
    console.log(`Target IP ${newIp} is already registered. No update needed.`);
    return { status: "no_change", ip: newIp };
  }

  // Deregister stale targets
  const staleTargets = currentTargets.filter((t) => t.Id !== newIp);
  await deregisterTargets(staleTargets);

  // Register new IP
  await registerTarget(newIp, RDS_PORT);

  const oldIps = staleTargets.map((t) => t.Id);
  console.log(`Successfully updated target group. Old IPs: ${oldIps} -> New IP: ${newIp}`);

  return { status: "updated", old_ips: oldIps, new_ip: newIp };
}
