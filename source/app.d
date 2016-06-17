import cached_response;

import vibe.d;
import std.stdio;
import std.typecons;

__gshared ResponseCache g_response_cache;


shared static this()
{
    g_response_cache = new ResponseCache();

    auto router = new URLRouter;
    router.any("*", &cached_proxy_request);

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
    // Copy relevant request headers
    upstream_req.method = req.method;
    foreach (key, value; req.headers)
    {
        // TODO: Remove any other fields? Transfer-Encoding?
        // TODO: Any special handling of "Host" field? For now we'll just assume we can always pass on the original request one
        // Some will just naturally get overwritten when we write the body
        if (icmp2(key, "Connection") != 0 &&     // Connection strategy is peer to peer
            icmp2(key, "Accept-Encoding") != 0)  // Similar with encoding strategy - we're going to decode in the middle
        {
            upstream_req.headers[key] = value;
        }
    }

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

    // TODO: Could try the read whole body, write whole body strategy here too I guess...?

    // If they provide a content length, use it
    if ("Content-Length" in req.headers)
        upstream_req.writeBody(req.bodyReader, upstream_req.headers["Content-Length"].to!size_t());
    else if (!req.bodyReader.empty)
    {
        // Chunked encoding... note that Steam servers don't seem too happy with this generally which
        // is why we try to avoid this path when proxying.
        upstream_req.writeBody(req.bodyReader);
    }
    // Otherwise don't write any request body
}


void setup_response(T)(int status_code, const(InetHeaderMap) upstream_headers, T body_reader, scope HTTPServerResponse res)
{
    // Copy relevant response headers
    res.statusCode = status_code;
    foreach (key, value; upstream_headers)
    {
        // TODO: Remove any other fields? Transfer-Encoding?
        // Some will just naturally get overwritten when we write the body
        if (icmp2(key, "Connection") != 0)
        {
            // NOTE: we need to dup the strings here as the response object passed in may be
            // transient (i.e. memory mapped file, etc).
            res.headers[key.idup] = value.idup;
        }
    }

    if (res.isHeadResponse) {
        res.writeVoidBody();
        return;
    }

    res.writeBody(body_reader);
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

    // Disable keep-alive for the moment - potentially just restrict the timeout in the future
    // TODO: Cache this settings object somewhere maybe - it's immutable really
    HTTPClientSettings settings = new HTTPClientSettings;
    settings.defaultKeepAliveTimeout = 0.seconds;

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
                        setup_response(response.status_code, response.headers, body_payload, res);
                    }
                );
            }
            else
            {
                // Don't cache, just pass through response
                // TODO: Should this count as a "BYPASS" instead of a "MISS"?
                setup_response(upstream_res.statusCode, upstream_res.headers, upstream_res.bodyReader, res);
            }
        },
        settings
    );
}


void cached_proxy_request(scope HTTPServerRequest req, scope HTTPServerResponse res)
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
                res.headers["X-Cache-Status"] = "HIT";
                setup_response(response.status_code, response.headers, body_payload, res);
            }
        );

        if (!found)
        {
            res.headers["X-Cache-Status"] = "MISS";
            upstream_request(req, res, cache_key);
        }
    }
    else
    {
        res.headers["X-Cache-Status"] = "BYPASS";
        upstream_request(req, res);
    }
}
