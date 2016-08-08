import cached_response;
import upstream_link_aggregator;

import vibe.d;
import std.stdio;
import std.typecons;
import std.algorithm;

__gshared ResponseCache g_response_cache;
__gshared UpstreamLinkAggregator g_upstream_link_aggregator;

shared static this()
{
    //setLogLevel(LogLevel.debugV);

    // Read command line arguments
    string upstream_address_list = "";
    readOption("upstream_interfaces|ui", &upstream_address_list, "Enables upstream link aggregation using the comma-separated list of interface addresses.");
    bool enable_cache = true;
    readOption("cache|c", &enable_cache, "Enables or disables proxy cache.");
    bool enable_multithreading = true;
    readOption("multithread|mt", &enable_multithreading, "Enables or disables multithreading.");

    g_response_cache = new ResponseCache();
    g_upstream_link_aggregator = new UpstreamLinkAggregator(split(upstream_address_list, ","));

    // TODO: We really should have a "host" router here as well, but since we have no real intention of
    // implementing a general purpose proxy, this is sufficient for the current steam server setup.
    auto router = new URLRouter;
    router.get("/depot/*", enable_cache ? &steam_depot : &steam_depot_uncached);    // Send steam /depot files to the cache path
    router.any("*", &uncached_upstream_request);                                    // Everything else just pass through (broadcasting, chat, etc. is on the same hosts)

	auto settings = new HTTPServerSettings;
	settings.port = 80;
    settings.options = HTTPServerOption.parseURL;
    if (enable_multithreading)
        settings.options |= HTTPServerOption.distribute;

    // Log something sorta like standard Apache output, but doesn't need to be exact
    settings.accessLogFormat = "%h - %u [%t] \"%r\" %s %b \"%{X-Cache-Status}o\" %v";
    //settings.accessLogFile = "access.log"; // Seems slightly buggy with distribute enabled
    settings.accessLogToConsole = true;

	listenHTTP(settings, router);
}


void setup_upstream_request(scope HTTPServerRequest req, scope HTTPClientRequest upstream_req)
{   
    upstream_req.method = req.method;
    upstream_req.headers = req.headers.dup;

    // Add standard proxy headers
    // NOTE: Disabled a few of these for now... none of them are really necessary for this application anyways
    //if (auto pfh = "X-Forwarded-Host" !in upstream_req.headers) 
    //    upstream_req.headers["X-Forwarded-Host"] = req.headers["Host"];
    //if (auto pfp = "X-Forwarded-Proto" !in upstream_req.headers)
    //    upstream_req.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";

    // TODO: Update to RFC7239 "Forwarded" header https://tools.ietf.org/html/rfc7239
    if (auto pri = "X-Real-IP" !in upstream_req.headers)
        upstream_req.headers["X-Real-IP"] = req.clientAddress.toAddressString();
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
}


void setup_cached_response_headers(int status_code, const(InetHeaderMap) upstream_headers, string cache_status,
                                   scope HTTPServerResponse res)
{
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
}


void setup_bypass_response(scope HTTPClientResponse upstream_res, scope HTTPServerResponse res)
{
    res.statusCode = upstream_res.statusCode;
    res.headers = upstream_res.headers.dup;

    res.headers["X-Cache-Status"] = "BYPASS";

    if (res.isHeadResponse)
        res.writeVoidBody();
    else
    {
        // TODO: Can detect certain cases and use writeRawBody and so on, but this is
        // generally more robust and doesn't seem to have failure cases or significant overhead yet
        res.bodyWriter.write(upstream_res.bodyReader);
    }
}


// If cache_key is empty, response will never be cached
void cached_upstream_request(scope HTTPServerRequest req, scope HTTPServerResponse res, string cache_key, bool upstream_aggregation = false)
{
    URL url;
    url.schema = "http";
    url.port = 80;
    url.host = req.host;
    url.localURI = req.requestURL;
    
    HTTPClientSettings settings = new HTTPClientSettings;

    // TODO: Could enable/disable use of link aggregation per-request depending on the route, etc.
    // For now we only have steam, for which even our simple endpoint unaware link aggregator works fine.
    Nullable!UpstreamInterface upstream_interface;
    if (upstream_aggregation) {
        upstream_interface = g_upstream_link_aggregator.acquire_interface();
        settings.networkInterface = upstream_interface.network_address;
    }
    scope(exit) {
        if (!upstream_interface.isNull())
            g_upstream_link_aggregator.release_interface(upstream_interface);
    }

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
            // eventually settles down and/or CPU overhead becomes an issue here, it's easy enough
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
                setup_cached_response_headers(upstream_res.statusCode, upstream_res.headers, "MISS", res);
                g_response_cache.cache_and_write_response_body(cache_key, upstream_res, res);
            }
            else
            {
                setup_bypass_response(upstream_res, res);
            }
        },
        settings
    );
}


bool check_proxy_recursive_loop(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    // Detect recursion (ex. if someone navigates directly to the host proxy address)
    // NOTE: This is not a completely robust test, but it works for our purposes
    if ("X-Steam-Proxy-Version" in req.headers)
    {
        res.headers["X-Cache-Status"] = "PROXY-LOOP";
        return true;
    }
    else
        return false;
}


// Any other uncached requests that we just want to pass through
void uncached_upstream_request(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    if (check_proxy_recursive_loop(req, res)) return;

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
            setup_bypass_response(upstream_res, res);
        },
    );
}



void steam_depot(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    if (check_proxy_recursive_loop(req, res)) return;

    // For Steam, we just use the path portion of the request, not host (they are mirrors)
    // or query params (per-user security stuff).
    string cache_key = "steam/" ~ req.path;

    // Check if we have it cached already
    auto found = g_response_cache.find(cache_key,
        (scope CachedHTTPResponse response, const(ubyte)[] body_payload)
        {
            setup_cached_response_headers(response.status_code, response.headers, "HIT", res);
            res.bodyWriter.write(body_payload);
        }
    );

    if (!found)
    {
        // Enable simple upstream aggregation (if available) since Steam depot servers
        // are not currently endpoint sensitive.
        cached_upstream_request(req, res, cache_key, true);
    }
}

void steam_depot_uncached(scope HTTPServerRequest req, scope HTTPServerResponse res)
{
    if (check_proxy_recursive_loop(req, res)) return;

    // Enable simple upstream aggregation (if available) since Steam depot servers
    // are not currently endpoint sensitive.
    cached_upstream_request(req, res, "", true);
}
