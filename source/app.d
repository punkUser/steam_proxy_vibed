import cached_response;

import vibe.d;
import std.stdio;

shared static ResponseCache g_response_cache;

shared static this()
{
    g_response_cache = new ResponseCache();

    auto router = new URLRouter;
    router.any("*", proxy_request());

	auto settings = new HTTPServerSettings;
	settings.port = 80;
    settings.options = HTTPServerOption.none; //HTTPServerOption.parseURL;

	listenHTTP(settings, router);
}

static void pretty_print_headers(InetHeaderMap headers)
{
    foreach (k, v ; headers)
        writefln("  %s: %s", k, v);
}


void setup_upstream_request(scope HTTPServerRequest req, scope HTTPClientRequest upstream_req)
{   
    // Copy relevant request headers
    upstream_req.method = req.method;
    foreach (key, value; upstream_req.headers) {
        // TODO: Remove any other fields? Transfer-Encoding?
        // TODO: Any special handling of "Host" field? For now we'll just assume we can always pass on the original request one
        // Some will just naturally get overwritten when we write the body
        if (icmp2(key, "Connection") != 0 ||     // Connection strategy is peer to peer
            icmp2(key, "Accept-Encoding") != 0)  // Avoid compressed responses as this path is potentially bugger in vibe.d currently
        {
            req.headers[key] = value;
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

    // If they provide a content length, use it
    if ("Content-Length" in req.headers)
        upstream_req.writeBody(req.bodyReader, upstream_req.headers["Content-Length"].to!size_t());
    else if (!req.bodyReader.empty)
    {
        // Chunked encoding... note that Steam servers don't seem too happy with this generally which
        // is why we try to avoid this path when proxying.
        upstream_req.writeBody(req.bodyReader);
    }
    // Otherwise don't write any body
}

void setup_upstream_response(scope HTTPClientResponse upstream_res, scope HTTPServerResponse res)
{
    // TODO: Decide whether to cache this response
    // For consistency, should we just always take the same path here?
    // i.e. do the request and cache it, then read it from the cache to satisfy the original
    // request? In theory the file cache should handle this reasonably well. If not we can
    // add some logic to the caching layer, but the advantage is guaranteed same behavior
    // for the "first" client that requests something and later ones that hit the cache.
    // That said, we also want as much consistency between the cached and not cached
    // request paths as possible, so there's no perfect answer.
    // NOTE: We choose the cache the upstream response rather than the modified response
    // that we send to the client here. This means slightly more overhead as even cache
    // hits have to run through the logic below again, but it means that the data in the
    // cache is far less coupled to any logic changes in the proxy code. If this code
    // eventually settings down and/or CPU overhead becomes an issue here, it's easy enough
    // to change.

    // Only cache "200" responses
    // Only cache "GET" and "HEAD" requests
    // Respect Cache-control: no cache request?
    // We need to ignore "expires" specifically for Steam as it is always set to immediate


    //auto cached_response = Bson([
    //"response": (cast(HTTPResponse)upstream_res).serializeToJson,
    //"field2": Bson(42),);

    //auto cached_response = Json([
    //    "response": (cast(HTTPResponse)upstream_res).serializeToJson()
    //]);
    //writeln(cached_response.toPrettyString());


    // Copy relevant response headers
    res.statusCode = upstream_res.statusCode;
    foreach (key, value; upstream_res.headers) {
        // TODO: Remove any other fields? Transfer-Encoding?
        // Some will just naturally get overwritten when we write the body
        if (icmp2(key, "Connection") != 0)
            res.headers[key] = value;
    }

    if (res.isHeadResponse) {
        res.writeVoidBody();
        return;
    }

    // If content length is specified, perform an almost raw copy of the response
    if ("Content-Length" in upstream_res.headers)
    {
        auto bodySize = upstream_res.headers["Content-Length"].to!size_t();

        if (bodySize == 0)
            res.writeBody(cast(ubyte[])"", null);
        else
        {
            auto payload = upstream_res.bodyReader.readAll();
            res.writeBody(payload);

            //cres.readRawBody((scope reader) {
            //    res.writeRawBody(reader, bodySize);
            //});
        }
        assert(res.headerWritten);

        //writeln("PROXY RESPONSE HEADERS:");
        //pretty_print_headers(res.headers);
        //writeln();

        return;
    }

    writeln("NOT IMPLEMENTED");
    assert(false);
    //throw new HTTPStatusException(HTTPStatus.notImplemented);
}


HTTPServerRequestDelegateS proxy_request()
{
	URL url;
	url.schema = "http";
    url.port = 80; // TODO: get from request somehow?

	void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		auto rurl = url;
        rurl.host = req.host;
		rurl.localURI = req.requestURL;

        // We don't currently support HTTP/1.0 clients
        if (res.httpVersion == HTTPVersion.HTTP_1_0) {
            throw new HTTPStatusException(HTTPStatus.httpVersionNotSupported);
        }

        // TODO: Decide whether to use cached response

        void upstream_request(scope HTTPClientRequest upstream_req)
        {
            setup_upstream_request(req, upstream_req);
        }

		void upstream_response(scope HTTPClientResponse upstream_res)
		{
            // Write the request right by the response to avoid trying to match them up manually
            writefln("REQUEST: %s", req.toString());
            writefln("UPSTREAM RESPONSE: %s", upstream_res.toString());
            writeln();

            setup_upstream_response(upstream_res, res);
		}

        // Disable keep-alive for the moment - potentially just restrict the timeout in the future
        // TODO: Cache this settings object somewhere maybe - it's immutable really
        HTTPClientSettings settings = new HTTPClientSettings;
        settings.defaultKeepAliveTimeout = 0.seconds; // closes connection immediately after receiving the data.

		requestHTTP(rurl, &upstream_request, &upstream_response, settings);
	}

	return &handleRequest;
}
