module upstream_link_aggregator;

import std.stdio;
import std.random;
import std.algorithm;
import vibe.d;

// For AF_INET definition
import core.sys.posix.netinet.in_;
version(Windows) import std.c.windows.winsock;

struct UpstreamInterface
{
    public NetworkAddress network_address = anyAddress();
    public int index = 0;
    public int outstanding_requests = 0;
};


// Simple upstream link aggregator/load balancer
// NOTE: Makes no attempt to be endpoint aware currently as Steam content servers do not seem to care
// NOTE: This object is intended to be thread safe (uses internal locking), and thus usage with "__gshared" is likely.
class UpstreamLinkAggregator
{
    public this(string[] bind_addresses = [])
    {
        m_mutex = new TaskMutex();

        if (bind_addresses.length > 0)
        {
            m_interfaces = new UpstreamInterface[bind_addresses.length];

            for (int i = 0; i < bind_addresses.length; ++i)
            {
                // TODO: ipv6?
                m_interfaces[i].network_address = resolveHost(bind_addresses[i], AF_INET, false);
                m_interfaces[i].index = i;
            }
        }
        else
        {
            // If they didn't provide any interfaces, just use the default one
            // TODO: Could fast path this better if needed (don't need to track anything or have mutexes at all)
            m_interfaces = new UpstreamInterface[1];
        }
    }

    public UpstreamInterface acquire_interface()
    {
        m_mutex.lock();
        scope (exit) m_mutex.unlock();

        // Find interface with least outstanding requests
        auto pos = minPos!"a.outstanding_requests < b.outstanding_requests"(m_interfaces);
        ++pos[0].outstanding_requests;
        return pos[0]; // Return a snapshot
    }

    public void release_interface(UpstreamInterface i)
    {
        m_mutex.lock();
        scope (exit) m_mutex.unlock();

        // Modify the real one, not the snapshot
        --m_interfaces[i.index].outstanding_requests;
    }

    // Protect access to interfaces with mutex
    TaskMutex m_mutex;
    private UpstreamInterface[] m_interfaces;
};
