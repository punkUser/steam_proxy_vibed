module cached_response;

import std.stdio;
import std.digest.md;
import std.file : mkdirRecurse;
import std.exception;
import std.mmfile;
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
    }

    // From HTTPResponse
    public int status_code;
    public InetHeaderMap headers;
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

    public bool find(string key,
                     void delegate(CachedHTTPResponse response, const(ubyte)[] body_payload) hit_handler)
    {
        //m_mutex.reader.lock();
        //scope(exit)m_mutex.reader.unlock();
        //return (key in m_memory_cache);
        
        auto path = cache_path(key);
        if (!existsFile(path)) return false;

        //auto data = readFile(path);
        // TODO: Any issues with using D MmFile instead of something that understand vibe and yielding?
        auto mmfile = new MmFile(path.toNativeString());
        scope(exit) destroy(mmfile);
        auto bson = Bson(Bson.Type.object, assumeUnique(cast(ubyte[])mmfile[]));
        auto response = deserializeBson!CachedHTTPResponse(bson);

        hit_handler(response, cast(const(ubyte)[])mmfile[bson.data.length .. cast(uint)mmfile.length]);

        return true;
    }

    // TODO: Probably need some sort of atomic "find or lock" ability to avoid races or duplicated work

    // TODO: Some way to lock a specific item in the cache while it is initially being filled
    // to avoid redoing work if multiple people request the same data at once.
    public void cache(string key, CachedHTTPResponse response, InputStream body_reader)
    {
        // TODO: Could reduce the scope of this lock if perf ever became an issue to only the
        // initial insertion of an empty slot into the map.
        //m_mutex.writer.lock();
        //scope(exit)m_mutex.writer.unlock();
        //m_memory_cache[key] = response;

        // TODO: Handle races or existence of file
        // TODO: At the very least, createTempFile for writing, move to final location after atomicly
        auto path = cache_path(key);
        auto bson = response.serializeToBson();
        mkdirRecurse(path.parentPath.toNativeString()); // TODO: This is a standard D call rather than vibe... is this a problem at all?

        auto file = openFile(path, FileMode.createTrunc);
        file.write(bson.data);
        file.write(body_reader);
        file.close();
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
