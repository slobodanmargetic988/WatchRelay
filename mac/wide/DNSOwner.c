#include <CoreFoundation/CoreFoundation.h>
#include <SystemConfiguration/SystemConfiguration.h>
#include <arpa/inet.h>
#include <ifaddrs.h>
#include <net/if.h>
#include <net/route.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

static const char tunnelAddress[] = "198.18.245.1";
static const char tunnelNetmask[] = "255.255.255.252";
static const char resolverAddress[] = "198.18.245.2";
static volatile sig_atomic_t stopping;

static void handleSignal(int signalNumber) {
    (void)signalNumber;
    stopping = 1;
}

static bool validInterfaceName(const char *name) {
    return strlen(name) < IFNAMSIZ &&
           strncmp(name, "utun", 4) == 0 &&
           name[4] != '\0' &&
           name[4 + strspn(name + 4, "0123456789")] == '\0';
}

static bool hasTunnelAddress(const char *name, unsigned int expectedIndex) {
    if (if_nametoindex(name) != expectedIndex) {
        return false;
    }

    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) {
        return false;
    }

    const unsigned int expectedFlags = IFF_UP | IFF_POINTOPOINT;
    const in_addr_t address = inet_addr(tunnelAddress);
    const in_addr_t netmask = inet_addr(tunnelNetmask);
    bool found = false;
    for (const struct ifaddrs *entry = interfaces; entry != NULL; entry = entry->ifa_next) {
        if (strcmp(entry->ifa_name, name) != 0 ||
            (entry->ifa_flags & expectedFlags) != expectedFlags ||
            entry->ifa_addr == NULL || entry->ifa_addr->sa_family != AF_INET ||
            entry->ifa_netmask == NULL || entry->ifa_netmask->sa_family != AF_INET) {
            continue;
        }
        const struct sockaddr_in *entryAddress = (const struct sockaddr_in *)entry->ifa_addr;
        const struct sockaddr_in *entryNetmask = (const struct sockaddr_in *)entry->ifa_netmask;
        if (entryAddress->sin_addr.s_addr == address && entryNetmask->sin_addr.s_addr == netmask) {
            found = true;
            break;
        }
    }
    freeifaddrs(interfaces);
    return found;
}

static bool addTemporaryValue(SCDynamicStoreRef store, CFStringRef key,
                              CFDictionaryRef value, const char *description) {
    if (SCDynamicStoreAddTemporaryValue(store, key, value)) {
        return true;
    }
    fprintf(stderr, "Could not register WatchRelay %s: %s\n", description, SCErrorString(SCError()));
    return false;
}

static bool registerResolver(SCDynamicStoreRef store, CFStringRef serviceName, CFStringRef interface) {
    CFStringRef dnsKey = SCDynamicStoreKeyCreateNetworkServiceEntity(
        NULL, kSCDynamicStoreDomainState, serviceName, kSCEntNetDNS);
    CFStringRef resolver = CFStringCreateWithCString(NULL, resolverAddress, kCFStringEncodingASCII);
    // An empty supplemental match domain applies to ordinary DNS queries even
    // when the tunnel is absent from the macOS network service list.
    const int searchOrder = 1;
    CFNumberRef order = CFNumberCreate(NULL, kCFNumberIntType, &searchOrder);
    const void *serverValues[] = {resolver};
    const void *domainValues[] = {CFSTR("")};
    const void *orderValues[] = {order};
    CFArrayRef servers = resolver == NULL ? NULL : CFArrayCreate(
        NULL, serverValues, 1, &kCFTypeArrayCallBacks);
    CFArrayRef domains = CFArrayCreate(NULL, domainValues, 1, &kCFTypeArrayCallBacks);
    CFArrayRef orders = order == NULL ? NULL : CFArrayCreate(
        NULL, orderValues, 1, &kCFTypeArrayCallBacks);

    bool added = false;
    if (dnsKey != NULL && servers != NULL && domains != NULL && orders != NULL) {
        const void *keys[] = {
            kSCPropInterfaceName,
            kSCPropNetDNSServerAddresses,
            kSCPropNetDNSSupplementalMatchDomains,
            kSCPropNetDNSSupplementalMatchOrders,
        };
        const void *values[] = {interface, servers, domains, orders};
        CFDictionaryRef dns = CFDictionaryCreate(
            NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
        if (dns != NULL) {
            added = addTemporaryValue(store, dnsKey, dns, "DNS");
            CFRelease(dns);
        }
    }

    if (orders != NULL) CFRelease(orders);
    if (domains != NULL) CFRelease(domains);
    if (servers != NULL) CFRelease(servers);
    if (order != NULL) CFRelease(order);
    if (resolver != NULL) CFRelease(resolver);
    if (dnsKey != NULL) CFRelease(dnsKey);
    return added;
}

static bool registerServiceRank(SCDynamicStoreRef store, CFStringRef serviceName) {
    CFStringRef serviceKey = SCDynamicStoreKeyCreateNetworkServiceEntity(
        NULL, kSCDynamicStoreDomainState, serviceName, NULL);
    const void *keys[] = {CFSTR("PrimaryRank")};
    const void *values[] = {CFSTR("Last")};
    CFDictionaryRef rank = CFDictionaryCreate(
        NULL, keys, values, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    bool added = serviceKey != NULL && rank != NULL &&
                 addTemporaryValue(store, serviceKey, rank, "service rank");
    if (rank != NULL) CFRelease(rank);
    if (serviceKey != NULL) CFRelease(serviceKey);
    return added;
}

static CFDictionaryRef createIPv4State(CFStringRef interface) {
    CFStringRef address = CFStringCreateWithCString(NULL, tunnelAddress, kCFStringEncodingASCII);
    CFStringRef netmask = CFStringCreateWithCString(NULL, tunnelNetmask, kCFStringEncodingASCII);
    const void *addressValues[] = {address};
    const void *netmaskValues[] = {netmask};
    CFArrayRef addresses = address == NULL ? NULL : CFArrayCreate(
        NULL, addressValues, 1, &kCFTypeArrayCallBacks);
    CFArrayRef netmasks = netmask == NULL ? NULL : CFArrayCreate(
        NULL, netmaskValues, 1, &kCFTypeArrayCallBacks);
    CFDictionaryRef state = NULL;
    if (addresses != NULL && netmasks != NULL) {
        const void *keys[] = {
            kSCPropInterfaceName, kSCPropNetIPv4Addresses, kSCPropNetIPv4SubnetMasks, kSCPropNetIPv4Router,
        };
        // Using the tunnel's own address as router makes configd's default on-link.
        const void *values[] = {interface, addresses, netmasks, address};
        state = CFDictionaryCreate(
            NULL, keys, values, sizeof(keys) / sizeof(keys[0]),
            &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    }
    if (netmasks != NULL) CFRelease(netmasks);
    if (addresses != NULL) CFRelease(addresses);
    if (netmask != NULL) CFRelease(netmask);
    if (address != NULL) CFRelease(address);
    return state;
}

static bool hasForeignPrimary(SCDynamicStoreRef store, CFArrayRef globalKeys, CFStringRef interface) {
    CFDictionaryRef state = SCDynamicStoreCopyMultiple(store, globalKeys, NULL);
    if (state == NULL) {
        return true;
    }
    bool foreign = false;
    for (CFIndex index = 0; index < CFArrayGetCount(globalKeys); ++index) {
        CFTypeRef global = CFDictionaryGetValue(state, CFArrayGetValueAtIndex(globalKeys, index));
        if (global == NULL) {
            continue;
        }
        CFTypeRef primary = CFGetTypeID(global) == CFDictionaryGetTypeID()
            ? CFDictionaryGetValue((CFDictionaryRef)global, kSCDynamicStorePropNetPrimaryInterface)
            : NULL;
        if (primary == NULL || !CFEqual(primary, interface)) {
            foreign = true;
            break;
        }
    }
    CFRelease(state);
    return foreign;
}

static bool bytesAreZero(const uint8_t *bytes, size_t length) {
    for (size_t index = 0; index < length; ++index) {
        if (bytes[index] != 0) {
            return false;
        }
    }
    return true;
}

static bool isDefaultRoute(const struct rt_msghdr2 *route, const uint8_t *address, size_t remaining) {
    const uint8_t *destination = NULL;
    const uint8_t *netmask = NULL;
    for (int slot = RTAX_DST; slot <= RTAX_NETMASK; ++slot) {
        if ((route->rtm_addrs & (1 << slot)) == 0) {
            continue;
        }
        if (remaining < sizeof(uint32_t)) {
            return false;
        }
        // Darwin's routing socket packs each sockaddr into a 4-byte boundary.
        size_t size = address[0] == 0 ? sizeof(uint32_t) : (address[0] + 3u) & ~3u;
        if (size > remaining) {
            return false;
        }
        if (slot == RTAX_DST) destination = address;
        if (slot == RTAX_NETMASK) netmask = address;
        address += size;
        remaining -= size;
    }
    if (destination == NULL || destination[0] < 2) {
        return false;
    }
    size_t offset;
    size_t width;
    if (destination[1] == AF_INET) {
        offset = offsetof(struct sockaddr_in, sin_addr);
        width = sizeof(struct in_addr);
    } else if (destination[1] == AF_INET6) {
        offset = offsetof(struct sockaddr_in6, sin6_addr);
        width = sizeof(struct in6_addr);
    } else {
        return false;
    }
    return destination[0] >= offset + width && bytesAreZero(destination + offset, width) &&
           (netmask == NULL || netmask[0] <= offset ||
            bytesAreZero(netmask + offset, netmask[0] - offset));
}

static bool hasForeignDefaultRoute(unsigned int interfaceIndex) {
    int query[] = {CTL_NET, PF_ROUTE, 0, AF_UNSPEC, NET_RT_DUMP2, 0};
    size_t length = 0;
    if (sysctl(query, 6, NULL, &length, NULL, 0) != 0) {
        return true;
    }
    length += 4096; // Leave room for route changes between the two reads.
    uint8_t *routes = malloc(length);
    if (routes == NULL) {
        return true;
    }
    bool foreign = true;
    if (sysctl(query, 6, routes, &length, NULL, 0) == 0) {
        const uint8_t *cursor = routes;
        while (length >= sizeof(struct rt_msghdr2)) {
            struct rt_msghdr2 route;
            memcpy(&route, cursor, sizeof(route));
            if (route.rtm_msglen < sizeof(route) || route.rtm_msglen > length ||
                route.rtm_version != RTM_VERSION) {
                break;
            }
            const int excluded = RTF_IFSCOPE | RTF_HOST | RTF_REJECT | RTF_BLACKHOLE;
            if (route.rtm_index != interfaceIndex && (route.rtm_flags & RTF_UP) != 0 &&
                (route.rtm_flags & excluded) == 0 &&
                isDefaultRoute(&route, cursor + sizeof(route), route.rtm_msglen - sizeof(route))) {
                break;
            }
            cursor += route.rtm_msglen;
            length -= route.rtm_msglen;
        }
        foreign = length != 0;
    }
    free(routes);
    return foreign;
}

static bool updateIPv4(SCDynamicStoreRef store, CFArrayRef globalKeys, CFStringRef interface,
                       unsigned int interfaceIndex, CFStringRef ipv4Key,
                       CFDictionaryRef ipv4State, bool *published) {
    bool offline = !hasForeignPrimary(store, globalKeys, interface) &&
                   !hasForeignDefaultRoute(interfaceIndex);
    if (offline == *published) {
        return true;
    }
    if (offline) {
        if (!addTemporaryValue(store, ipv4Key, ipv4State, "offline IPv4 service")) {
            return false;
        }
        fputs("WatchRelay published its offline IPv4 service.\n", stderr);
    } else {
        if (!SCDynamicStoreRemoveValue(store, ipv4Key) && SCError() != kSCStatusNoKey) {
            fprintf(stderr, "Could not withdraw WatchRelay offline IPv4 service: %s\n",
                    SCErrorString(SCError()));
            return false;
        }
        fputs("WatchRelay withdrew its offline IPv4 service.\n", stderr);
    }
    *published = offline;
    return true;
}

static int runService(SCDynamicStoreRef store, const char *interfaceName,
                      unsigned int interfaceIndex, pid_t owner) {
    CFUUIDRef uuid = CFUUIDCreate(NULL);
    CFStringRef serviceName = uuid == NULL ? NULL : CFUUIDCreateString(NULL, uuid);
    CFStringRef interface = CFStringCreateWithCString(NULL, interfaceName, kCFStringEncodingASCII);
    CFStringRef ipv4Key = serviceName == NULL ? NULL : SCDynamicStoreKeyCreateNetworkServiceEntity(
        NULL, kSCDynamicStoreDomainState, serviceName, kSCEntNetIPv4);
    CFDictionaryRef ipv4State = interface == NULL ? NULL : createIPv4State(interface);
    const void *globalKeyValues[] = {CFSTR("State:/Network/Global/IPv4"), CFSTR("State:/Network/Global/IPv6")};
    CFArrayRef globalKeys = CFArrayCreate(NULL, globalKeyValues, 2, &kCFTypeArrayCallBacks);

    int result = 1;
    bool published = false;
    if (serviceName != NULL && interface != NULL && ipv4Key != NULL && ipv4State != NULL &&
        globalKeys != NULL && registerServiceRank(store, serviceName) &&
        registerResolver(store, serviceName, interface) &&
        !stopping && getppid() == owner && hasTunnelAddress(interfaceName, interfaceIndex) &&
        updateIPv4(store, globalKeys, interface, interfaceIndex, ipv4Key, ipv4State, &published)) {
        char serviceID[37];
        if (CFStringGetCString(serviceName, serviceID, sizeof(serviceID), kCFStringEncodingASCII)) {
            fprintf(stderr, "WatchRelay dynamic store service %s\n", serviceID);
        }
        printf("READY %s %s\n", interfaceName, resolverAddress);
        fflush(stdout);
        result = 0;
        const struct timespec interval = {.tv_sec = 1};
        while (!stopping && getppid() == owner && hasTunnelAddress(interfaceName, interfaceIndex)) {
            if (!updateIPv4(store, globalKeys, interface, interfaceIndex, ipv4Key, ipv4State, &published)) {
                result = 1;
                break;
            }
            nanosleep(&interval, NULL);
        }
    }
    if (globalKeys != NULL) CFRelease(globalKeys);
    if (ipv4State != NULL) CFRelease(ipv4State);
    if (ipv4Key != NULL) CFRelease(ipv4Key);
    if (interface != NULL) CFRelease(interface);
    if (serviceName != NULL) CFRelease(serviceName);
    if (uuid != NULL) CFRelease(uuid);
    return result;
}

int main(int argc, char **argv) {
    if (argc != 2 || !validInterfaceName(argv[1])) {
        fprintf(stderr, "Usage: dns-owner utunN\n");
        return 64;
    }
    const char *interfaceName = argv[1];
    const pid_t owner = getppid();
    const unsigned int interfaceIndex = if_nametoindex(interfaceName);
    if (owner <= 1 || interfaceIndex == 0 || !hasTunnelAddress(interfaceName, interfaceIndex)) {
        fprintf(stderr, "WatchRelay tunnel %s is unavailable or has the wrong address\n", interfaceName);
        return 1;
    }

    struct sigaction action = {.sa_handler = handleSignal};
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGTERM, &action, NULL) != 0 || sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGHUP, &action, NULL) != 0 || sigaction(SIGQUIT, &action, NULL) != 0) {
        perror("Could not install WatchRelay DNS signal handlers");
        return 1;
    }

    SCDynamicStoreRef store = SCDynamicStoreCreate(NULL, CFSTR("WatchRelay DNS"), NULL, NULL);
    if (store == NULL) {
        fprintf(stderr, "Could not open the macOS dynamic store: %s\n", SCErrorString(SCError()));
        return 1;
    }
    int result = runService(store, interfaceName, interfaceIndex, owner);
    // Closing this session removes its temporary service keys, including after a crash.
    CFRelease(store);
    return result;
}
