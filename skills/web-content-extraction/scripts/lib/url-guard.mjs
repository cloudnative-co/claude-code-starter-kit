// SSRF / private-URL guard for the web-content-extraction skill.
//
// Blocks requests to localhost, private/reserved IP ranges, link-local, and
// internal-looking hostnames by DEFAULT. Set ALLOW_PRIVATE_URLS=true to override
// for dev use (each bypass is audited to stderr).
//
// Defense in depth:
//   1. Protocol allow-list (http/https only) + userinfo rejection.
//   2. Hostname pattern checks (localhost, .local/.internal/..., bare hostnames).
//   3. Byte-level IP classification — handles decimal/octal/hex IPv4 (normalised
//      by the WHATWG URL parser) AND IPv4-mapped IPv6 in compressed hex form
//      (e.g. [::ffff:127.0.0.1] -> ::ffff:7f00:1).
//   4. createGuardedLookup(): a DNS lookup for undici's connector that validates
//      the *actual* connect IPs, closing the DNS-rebinding / TOCTOU window
//      between guard-time resolution and fetch-time resolution.

import dns from 'node:dns/promises'
import net from 'node:net'

const INTERNAL_TLDS = ['.local', '.localhost', '.internal', '.intranet', '.lan', '.home', '.corp', '.private']

function envAllowsPrivate() {
  return String(process.env.ALLOW_PRIVATE_URLS ?? '').toLowerCase() === 'true'
}

/** Audit a private-URL bypass to stderr (never stdout, which is reserved for JSON). */
function auditBypass(detail) {
  process.stderr.write(`[url-guard] ALLOW_PRIVATE_URLS=true bypass: ${detail}\n`)
}

function guardError(code, message) {
  const error = new Error(message)
  error.code = code
  return error
}

/** Convert an IPv4 string to a 32-bit unsigned integer. */
function ipv4ToInt(ip) {
  return ip.split('.').reduce((acc, oct) => (acc << 8) + Number(oct), 0) >>> 0
}

/** True if an IPv4 address is private / reserved / non-routable. */
function isPrivateIPv4(ip) {
  const n = ipv4ToInt(ip)
  const inRange = (cidr, bits) => (n >>> (32 - bits)) === (ipv4ToInt(cidr) >>> (32 - bits))
  return (
    inRange('0.0.0.0', 8) ||      // "this" network
    inRange('10.0.0.0', 8) ||     // private
    inRange('100.64.0.0', 10) ||  // CGNAT
    inRange('127.0.0.0', 8) ||    // loopback
    inRange('169.254.0.0', 16) || // link-local
    inRange('172.16.0.0', 12) ||  // private
    inRange('192.0.0.0', 24) ||   // IETF protocol assignments
    inRange('192.168.0.0', 16) || // private
    inRange('198.18.0.0', 15) ||  // benchmarking
    inRange('224.0.0.0', 4) ||    // multicast
    inRange('240.0.0.0', 4)       // reserved
  )
}

/**
 * Parse an IPv6 string (incl. `::` compression and embedded dotted IPv4) into
 * 16 bytes. Returns null if it is not a valid IPv6 literal.
 */
function parseIPv6ToBytes(input) {
  const str = input.split('%')[0] // drop zone id
  if (!net.isIPv6(str)) return null

  const [head, tail] = str.split('::')
  const expand = (part) => (part ? part.split(':').filter((g) => g !== '') : [])
  let left = expand(head)
  let right = tail === undefined ? [] : expand(tail)

  // Embedded dotted IPv4 in the last group -> two hextets.
  const embedV4 = (groups) => {
    if (groups.length && groups[groups.length - 1].includes('.')) {
      const v4 = groups.pop()
      const o = v4.split('.').map((n) => Number(n))
      groups.push(((o[0] << 8) | o[1]).toString(16), ((o[2] << 8) | o[3]).toString(16))
    }
  }
  embedV4(left)
  embedV4(right)

  const missing = 8 - (left.length + right.length)
  if (tail === undefined && missing !== 0) return null
  const groups = tail === undefined ? left : [...left, ...Array(missing).fill('0'), ...right]
  if (groups.length !== 8) return null

  const bytes = new Uint8Array(16)
  for (let i = 0; i < 8; i++) {
    const v = parseInt(groups[i] || '0', 16)
    bytes[i * 2] = (v >> 8) & 0xff
    bytes[i * 2 + 1] = v & 0xff
  }
  return bytes
}

/**
 * True if a 16-byte IPv6 address must be treated as non-public.
 *
 * Default-deny: ONLY global unicast 2000::/3 is allowed, and within it the known
 * special-purpose sub-ranges are still blocked. Everything else (loopback,
 * unspecified, ULA, link-local, site-local, multicast, IPv4-mapped/compatible,
 * NAT64, discard, etc.) is blocked outright. This is robust against the long
 * tail of IPv6 special-use prefixes (RFC 6890 / IANA) that a denylist forgets.
 */
function isPrivateIPv6Bytes(b) {
  const embeddedV4 = (i) => `${b[i]}.${b[i + 1]}.${b[i + 2]}.${b[i + 3]}`

  // Allow only global unicast 2000::/3 (top 3 bits = 001). Blocks ::, ::1,
  // ::ffff:0:0/96, ::/96, 64:ff9b::/96 (all in 0000::/8), fc00::/7, fe80::/10,
  // fec0::/10, ff00::/8, etc.
  if ((b[0] & 0xe0) !== 0x20) return true

  // Within 2000::/3, block special-purpose sub-ranges.
  if (b[0] === 0x20 && b[1] === 0x01) {
    if (b[2] === 0x0d && b[3] === 0xb8) return true // 2001:db8::/32 documentation
    if (b[2] === 0x00 && b[3] === 0x00) return true // 2001::/32 Teredo
    if (b[2] === 0x00 && b[3] === 0x02 && b[4] === 0x00 && b[5] === 0x00) return true // 2001:2::/48 benchmarking
    if (b[2] === 0x00 && b[3] >= 0x10 && b[3] <= 0x3f) return true // 2001:10::/28 + 2001:20::/28 ORCHID
  }
  // 6to4 2002::/16 -> routes to the embedded IPv4; block if that v4 is private.
  if (b[0] === 0x20 && b[1] === 0x02) return isPrivateIPv4(embeddedV4(2))

  return false
}

/** True if a literal IP string is private/reserved (IPv4 or IPv6, any notation). */
export function isPrivateIp(ip) {
  if (net.isIPv4(ip)) return isPrivateIPv4(ip)
  if (net.isIPv6(ip)) {
    const bytes = parseIPv6ToBytes(ip)
    return bytes ? isPrivateIPv6Bytes(bytes) : true // unparseable -> treat as unsafe
  }
  return false
}

/** True if a hostname *looks* internal even before DNS resolution. */
function isInternalHostname(hostname) {
  const h = hostname.toLowerCase().replace(/\.$/, '')
  if (h === 'localhost') return true
  if (INTERNAL_TLDS.some((tld) => h.endsWith(tld))) return true
  if (!h.includes('.') && !net.isIP(h)) return true // bare single-label host
  return false
}

/**
 * Assert that a URL is safe to fetch from the public internet.
 * Throws an Error (with a clear Japanese message) when the URL is blocked.
 * @param {string} rawUrl
 * @returns {Promise<URL>} the parsed, validated URL
 */
export async function assertPublicUrl(rawUrl) {
  let parsed
  try {
    parsed = new URL(rawUrl)
  } catch {
    throw guardError('MALFORMED_URL', `不正なURL: ${rawUrl}`)
  }

  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') {
    throw guardError('BLOCKED_PROTOCOL', `許可されていないプロトコル: ${parsed.protocol} (http/https のみ許可)`)
  }

  // Reject embedded credentials: they leak into output/logs and enable abuse.
  if (parsed.username || parsed.password) {
    throw guardError('BLOCKED_CREDENTIALS', '認証情報付きURL(user:pass@)は拒否')
  }

  const allowPrivate = envAllowsPrivate()
  const hostname = parsed.hostname.replace(/^\[|\]$/g, '') // strip IPv6 brackets

  if (net.isIP(hostname)) {
    if (isPrivateIp(hostname)) {
      if (!allowPrivate) {
        throw guardError('BLOCKED_IP', `プライベート/内部IPは拒否: ${hostname} (開発用途なら ALLOW_PRIVATE_URLS=true)`)
      }
      auditBypass(`private IP ${hostname}`)
    }
    return parsed
  }

  if (isInternalHostname(hostname)) {
    if (!allowPrivate) {
      throw guardError('BLOCKED_HOSTNAME', `内部ホスト名らしきURLは拒否: ${hostname} (開発用途なら ALLOW_PRIVATE_URLS=true)`)
    }
    auditBypass(`internal hostname ${hostname}`)
    return parsed
  }

  // DNS resolution check (skipped when explicitly allowed).
  if (!allowPrivate) {
    let addrs
    try {
      addrs = await dns.lookup(hostname, { all: true })
    } catch (error) {
      throw guardError('DNS_FAIL', `DNS解決に失敗: ${hostname} (${error?.code ?? error?.message ?? 'unknown'})`)
    }
    const privateHit = addrs.find((a) => isPrivateIp(a.address))
    if (privateHit) {
      throw guardError('BLOCKED_DNS_IP', `ホスト名がプライベートIPに解決されたため拒否: ${hostname} -> ${privateHit.address} (開発用途なら ALLOW_PRIVATE_URLS=true)`)
    }
  } else {
    auditBypass(`DNS guard skipped for ${hostname}`)
  }

  return parsed
}

/**
 * Build a DNS lookup function for undici's connector. It resolves the hostname
 * and validates EVERY returned address; if any is private (and not allowed) the
 * connection is refused. Because undici connects to exactly these addresses,
 * the guard and the actual connection share one resolution — closing the
 * DNS-rebinding / TOCTOU window.
 * @returns {(hostname: string, options: object, callback: Function) => void}
 */
export function createGuardedLookup() {
  const allowPrivate = envAllowsPrivate()
  return (hostname, options, callback) => {
    const wantAll = !!(options && options.all)
    // Force all+verbatim AFTER the spread so a caller's `all:false` cannot turn
    // the result into a single object (which would break the array validation).
    dns.lookup(hostname, { ...options, all: true, verbatim: true }).then(
      (addrs) => {
        if (!Array.isArray(addrs) || addrs.length === 0) {
          callback(guardError('DNS_EMPTY', `接続拒否: ${hostname} の名前解決結果が空`))
          return
        }
        if (!allowPrivate) {
          const bad = addrs.find((a) => isPrivateIp(a.address))
          if (bad) {
            callback(guardError('BLOCKED_DNS_IP', `接続拒否: ${hostname} がプライベートIP ${bad.address} に解決`))
            return
          }
        }
        // Honour the ORIGINAL callback shape requested by the caller.
        if (wantAll) callback(null, addrs)
        else callback(null, addrs[0].address, addrs[0].family)
      },
      (err) => callback(err),
    )
  }
}
