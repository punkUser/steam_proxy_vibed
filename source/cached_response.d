module cached_response;

import vibe.d;

class CachedHTTPResponse
{
    // Pulls all of the relevant data (including reads whole body!) from the given client
    // upstream response and stores it in this object.
    public this(HTTPClientResponse upstream_res)
    {
        status_code = upstream_res.statusCode;
        headers = upstream_res.headers.dup;
        body_payload = upstream_res.bodyReader.readAll();
    }

    // From HTTPResponse
    public int status_code;
    public const(InetHeaderMap) headers;
    public const(ubyte)[] body_payload;
};

// The monolithic cache object that handles checking for requests and caching the results
// NOTE: This object is intended to be thread safe (uses internal locking), and thus usage
// with "__gshared" is likely.
class ResponseCache
{
    public this()
    {
        // TODO: Experiment with mutex policies, although it's hard to imagine a case where
        // we should be high contention here given the latencies of network requests and so on.
        m_mutex = new TaskReadWriteMutex();
    }

    public const(CachedHTTPResponse)* find(string key)
    {
        m_mutex.reader.lock();
        scope(exit)m_mutex.reader.unlock();
        return (key in m_cache);
    }

    // TODO: Some way to lock a specific item in the cache while it is initially being filled
    // to avoid redoing work if multiple people request the same data at once.
    public void cache(string key, CachedHTTPResponse response)
    {
        // TODO: Could reduce the scope of this lock if perf ever became an issue to only the
        // initial insertion of an empty slot into the map.
        m_mutex.writer.lock();
        scope(exit)m_mutex.writer.unlock();
        m_cache[key] = response;
    }

    private TaskReadWriteMutex m_mutex;
    private CachedHTTPResponse[string] m_cache;
};
