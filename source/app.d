import cached_response;

import vibe.d;
import std.stdio;
import std.typecons;

__gshared ResponseCache g_response_cache;


shared static this()
{
    g_response_cache = new ResponseCache();

    auto router = new URLRouter;
    router.any("/depot/*", &steam_depot);   // Send steam /depot files to the cache path
    router.any("*", &uncached);             // Everything else just pass through (broadcasting, chat, etc. is on the same hosts)

	auto settings = new HTTPServerSettings;
	settings.port = 80;
    settings.options = HTTPServerOption.parseURL | HTTPServerOption.distribute;

    // Log something sorta like standard Apache output, but doesn't need to be exact
    settings.accessLogFormat = "%h - %u [%t] \"%r\" %s %b \"%{X-Cache-Status}o\" %v";
    //settings.accessLogFile = "access.log";
    settings.accessLogToConsole = true;

	listenHTTP(settings, router);
}


void setup_upstream_request(scope HTTPServerRequest req, scope HTTPClientRequest upstream_req)
{   
    upstream_req.method = req.method;
    upstream_req.headers = req.headers.dup;

    // Add standard proxy headers
    if (auto pri = "X-Real-IP" !in upstream_req.headers)
        upstream_req.headers["X-Real-IP"] = req.clientAddress.toAddressString();
    if (auto pfh = "X-Forwarded-Host" !in upstream_req.headers) 
        upstream_req.headers["X-Forwarded-Host"] = req.headers["Host"];
    if (auto pfp = "X-Forwarded-Proto" !in upstream_req.headers)
        upstream_req.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";
    if (auto pff = "X-Forwarded-For" in req.headers)
        upstream_req.headers["X-Forwarded-For"] = *pff ~ ", " ~ req.peer;
    else
        upstream_req.headers["X-Forwarded-For"] = req.peer;

    // This is our silly way of detecting recursion...
    upstream_req.headers["X-Steam-Proxy-Version"] = "1"; // TODO if we care about version number properly

    if ("Content-Length" in req.headers)
    {
        // If they provide a content length, use it
        auto length = upstream_req.headers["Content-Length"].to!size_t();
        upstream_req.bodyWriter.write(req.bodyReader, length);
    }
    else if (!req.bodyReader.empty)
    {
        // Chunked encoding... note that Steam servers don't seem too happy with this generally which
        // is why we try to avoid this path when proxying.
        upstream_req.bodyWriter.write(req.bodyReader);
    }
    else
    {
        // Otherwise don't write any request body
    }
}


void setup_cached_response(T)(int status_code, const(InetHeaderMap) upstream_headers, T body_reader, scope HTTPServerResponse res,
                              string cache_status = "")
{
    // Copy relevant response headers
    res.statusCode = status_code;

    // Can't just dup here since we need to dup each string; the response object passed in may be transiet (mmap'd file, etc)
    res.headers = InetHeaderMap.init;
    foreach (key, value; upstream_headers)
    {
        //writefln("%s: %s", key, value); // DEBUG
        res.headers[key.idup] = value.idup;
    }

    if (!cache_status.empty)
        res.headers["X-Cache-Status"] = cache_status;

    if (res.isHeadResponse)
    {
        res.writeVoidBody();
    }
    else
    {
        // NOTE: writeRawBody would potentially be better here in the passthrough cases - might be worth specializing
        res.bodyWriter.write(body_reader);
    }
}


// If cache_key is empty, response will never be cached
void upstream_request(scope HTTPServerRequest req, scope HTTPServerResponse res, string cache_key = "")
{
    // Detect recursion (ex. if someone navigates directly to the host proxy address)
    // NOTE: This is not a completely robust test, but it works for our purposes
    if ("X-Steam-Proxy-Version" in req.headers)
        return; // This will result in an error page due to not writing a response

    URL url;
    url.schema = "http";
    url.port = 80;
    url.host = req.host;
    url.localURI = req.requestURL;

    requestHTTP(url,
        (scope HTTPClientRequest upstream_req)
        {
            setup_upstream_request(req, upstream_req);
        },
        (scope HTTPClientResponse upstream_res) 
        {
            // NOTE: We choose the cache the upstream response rather than the modified response
            // that we send to the client here. This means slightly more overhead as even cache
            // hits have to run through the logic below again, but it means that the data in the
            // cache is far less coupled to any logic changes in the proxy code. If this code
            // eventually settings down and/or CPU overhead becomes an issue here, it's easy enough
            // to change.

            // Decide whether to cache this response
            bool cache =
                (!cache_key.empty) &&
                (req.method == HTTPMethod.GET) &&
                (upstream_res.statusCode == HTTPStatus.OK);

            // TODO: Respect Cache-control: no cache request?
            // We need to ignore "expires" specifically for Steam as it is always set to immediate

            if (cache)
            {
                // NOTE: This is *destructive* on the body data in upstream_res!
                g_response_cache.cache(cache_key, upstream_res);

                // Should now be in the cache, so reload it from there for this response
                auto found = g_response_cache.find(cache_key,
                    (scope CachedHTTPResponse response, const(ubyte)[] body_payload)
                    {
                        setup_cached_response(response.status_code, response.headers, body_payload, res, "MISS");
                    }
                );
            }
            else
            {
                setup_cached_response(upstream_res.statusCode, upstream_res.headers, upstream_res.bodyReader, res, "BYPASS");
            }
        },
    );
}


void steam_depot(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    // Decide whether to use cached responses for this request
    string cache_key = "";
    if (req.method == HTTPMethod.GET)
    {
        // Determine cache key
        // For Steam, we just use the path portion of the request, not host (they are mirrors) or query params (per-user security stuff)
        // TODO: Obviously we should constrain/specialize this logic for just steam requests for robustness even though
        // we have no intention of implementing a general-purpose proxy cache here.
        cache_key = "steam/" ~ req.path;

        // Check if we have it cached already
        auto found = g_response_cache.find(cache_key,
            (scope CachedHTTPResponse response, const(ubyte)[] body_payload)
            {
                setup_cached_response(response.status_code, response.headers, body_payload, res, "HIT");
            }
        );

        if (!found)
            upstream_request(req, res, cache_key);
    }
    else
    {
        upstream_request(req, res);
    }
}

// Any other uncached requests that we just want to pass through
void uncached(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    upstream_request(req, res);
}
