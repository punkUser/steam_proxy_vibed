module cached_response;

import std.stdio;
import std.digest.md;
import std.file : mkdirRecurse;
import std.exception;
import std.mmfile;
import core.memory;
import vibe.d;

struct CachedHTTPResponse
{
    public int status_code;
    public InetHeaderMap headers;
};

// The monolithic cache object that handles checking for requests and caching the results
// NOTE: This object is intended to be thread safe (uses internal locking), and thus usage
// with "__gshared" is likely.
// TODO: This entire class is basically "static" right now since we (ab)use the file system
// to do our locking and synchronization and so on. Could change the interface/design given that.
class ResponseCache
{
    public this()
    {
    }

    public static bool find(string key,
        void delegate(scope CachedHTTPResponse response, const(ubyte)[] body_payload) hit_handler)
    {        
        auto path = cache_path(key);
        //if (!existsFile(path)) return false;

        try
        {
            // TODO: Any issues with using D MmFile instead of something that understand vibe and yielding?
            auto mmfile = new MmFile(path.toNativeString());
            scope(exit) destroy(mmfile);
            auto bson = Bson(Bson.Type.object, assumeUnique(cast(ubyte[])mmfile[]));
            auto response = deserializeBson!CachedHTTPResponse(bson);

            hit_handler(response, cast(const(ubyte)[])mmfile[bson.data.length .. cast(uint)mmfile.length]);

            return true;
        }
        // TODO: Catch a less general exception type... but MmFile seems to throw a windows-specific
        // system exception on Windows and I'd rather not be *platform*-specific here.
        catch (Exception e)
        {
            // Response not yet in the cache
            return false;
        }
    }

    // TODO: Some way to lock a specific item in the cache while it is initially being filled
    // to avoid redoing work if multiple people request the same data at once.
    // NOTE: Destructively reads the body of the upstream response - thus the caller needs to
    // call "find" to grab that data from the cache again if necessary.
    public static void cache(string key, HTTPClientResponse upstream_res)
    {
        // TODO: Handle races or existence of file

        // Create temp file for caching the response.
        // NOTE: On Windows this seems to create the temporary file in the current directory...
        // This is non-ideal, so we may want to roll our own with std.file.tempDir or similar
        auto file = create_temporary_file();
        scope(failure) file.close();

        CachedHTTPResponse cached_response;
        cached_response.status_code = upstream_res.statusCode;
        cached_response.headers = upstream_res.headers.dup;
        auto bson = cached_response.serializeToBson();

        file.write(bson.data);
        file.write(upstream_res.bodyReader);

        auto temp_file_path = file.path;
        file.close();

        // Move temp file to the cached path
        auto cached_path = cache_path(key);
        // TODO: This is a standard D call rather than vibe... is this a problem at all?
        mkdirRecurse(cached_path.parentPath.toNativeString());
        moveFile(temp_file_path, cached_path, true);
    }

    // Mapping of cache key -> file name
    private static Path cache_path(string key)
    {
        // For the case of steam it makes more sense to at least respect the URL portion that contains the APP ID
        // That way we retain the ability to manually clear out certain applications from the cache.
        string path_string = "cache/" ~ key;
        return Path(path_string);

        // More general sol'n: a simple scheme of MD5 the key, then store it in "cache/AB/CD" where
        // AB and CD are the first 4 digits of the hash (to make the file system a bit happier).
        //string md5_string = toHexString(md5Of(key));
        //string path_string = format("cache/%s/%s/%s", md5_string[0..2], md5_string[2..4], md5_string);
    }

    // Our own version since vibe's puts this in the current working directory :S
    private static FileStream create_temporary_file()
    {
        import std.file : tempDir;
        import std.conv : to;

		char[L_tmpnam] tmp;
		tmpnam(tmp.ptr);
		auto tmpname = to!string(tmp.ptr);
		if (tmpname.startsWith("\\")) tmpname = tmpname[1 .. $];
		
		return openFile(tempDir() ~ "/" ~ tmpname, FileMode.createTrunc);
    }
};
