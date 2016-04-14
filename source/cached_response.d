module cached_response;

import std.stdio;
import std.digest.md;
import std.file : mkdirRecurse;
import std.exception;
import core.memory;
import vibe.d;

class CachedHTTPResponse
{
    public this() {}

    // Pulls all of the relevant data (including reads whole body!) from the given client
    // upstream response and stores it in this object.
    // Method rather than 
    public void create(HTTPClientResponse upstream_res)
    {
        status_code = upstream_res.statusCode;
        headers = upstream_res.headers.dup;

        body_payload = upstream_res.bodyReader.readAll();
    }

    // From HTTPResponse
    public int status_code;
    public InetHeaderMap headers;
    public ubyte[] body_payload;
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

    public Nullable!CachedHTTPResponse find(string key)
    {
        //m_mutex.reader.lock();
        //scope(exit)m_mutex.reader.unlock();
        //return (key in m_memory_cache);
        
        auto path = cache_path(key);
        if (!existsFile(path)) return Nullable!CachedHTTPResponse();

        auto data = readFile(path);
        auto bson = Bson(Bson.Type.object, assumeUnique(data));
        auto response = deserializeBson!CachedHTTPResponse(bson);
        return Nullable!CachedHTTPResponse(response);
    }

    // TODO: Probably need some sort of atomic "find or lock" ability to avoid races or duplicated work

    // TODO: Some way to lock a specific item in the cache while it is initially being filled
    // to avoid redoing work if multiple people request the same data at once.
    public void cache(string key, CachedHTTPResponse response)
    {
        // TODO: Could reduce the scope of this lock if perf ever became an issue to only the
        // initial insertion of an empty slot into the map.
        //m_mutex.writer.lock();
        //scope(exit)m_mutex.writer.unlock();
        //m_memory_cache[key] = response;

        // TODO: Handle races or existence of file
        auto path = cache_path(key);
        auto bson = response.serializeToBson();
        mkdirRecurse(path.parentPath.toNativeString()); // TODO: This is a standard D call rather than vibe... is this a problem at all?
        writeFile(path, bson.data);

        //writefln("SIZE OVERHEAD: %s", (bson.data.length - response.body_payload.length) / cast(float)response.body_payload.length);
    }

    // Mapping of cache key -> file name
    private Path cache_path(string key)
    {
        // For now we go with a simple scheme of MD5 the key, then store it in "cache/AB/CD" where
        // AB and CD are the first 4 digits of the hash (to make the file system a bit happier).
        // TODO: For the case of steam it probably makes more sense to at least respect the URL portion that contains the APP ID
        // That way we retain the ability to manually clear out certain applications from the cache.
        /*
        string md5_string = toHexString(md5Of(key));
        string path_string = format("cache/%s/%s/%s", md5_string[0..2], md5_string[2..4], md5_string);
        */
        string path_string = "cache/" ~ key;
        return Path(path_string);
    }

    private TaskReadWriteMutex m_mutex;
    private CachedHTTPResponse[string] m_memory_cache;
};
