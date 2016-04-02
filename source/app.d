import vibe.d;
import std.stdio;

shared static this()
{
    auto router = new URLRouter;
    router.any("*", proxyRequest());

	auto settings = new HTTPServerSettings;
	settings.port = 80;
    settings.options = HTTPServerOption.none; //HTTPServerOption.parseURL;

	listenHTTP(settings, router);
}

static void pretty_print_headers(InetHeaderMap headers)
{
    foreach (k, v ; headers)
    {
        writefln("  %s: %s", k, v);
    }
}

/**
Returns a HTTP request handler that forwards any request to the specified host/port.
*/
HTTPServerRequestDelegateS proxyRequest()
{
	URL url;
	url.schema = "http";
    url.port = 80; // TODO: get from request somehow?

	void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		auto rurl = url;
        rurl.host = req.host;
		rurl.localURI = req.requestURL;

        // TODO: Decide whether to use cached response

		void setupClientRequest(scope HTTPClientRequest creq)
		{
            writeln("REQUEST:");
            writefln("%s %s", req.method, req.requestURL);
            pretty_print_headers(req.headers);

            // TODO: Any other headers we want to manipulate or not copy?
			creq.method = req.method;
			creq.headers = req.headers.dup;
			creq.headers["Connection"] = "keep-alive";

            // if (auto pfh = "X-Real-IP" !in creq.headers) creq.headers["X-Real-IP"] = creq.clientAddress.toAddressString();
			if (auto pfh = "X-Forwarded-Host" !in creq.headers) creq.headers["X-Forwarded-Host"] = req.headers["Host"];
			if (auto pfp = "X-Forwarded-Proto" !in creq.headers) creq.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";
			if (auto pff = "X-Forwarded-For" in req.headers) creq.headers["X-Forwarded-For"] = *pff ~ ", " ~ req.peer;
			else creq.headers["X-Forwarded-For"] = req.peer;
            
            // If they provide a content length, use it
            if ("Content-Length" in req.headers)
                creq.writeBody(req.bodyReader, req.headers["Content-Length"].to!size_t());
            else if (!req.bodyReader.empty)
            {
                // Chunked encoding... note that Steam servers don't seem too happy with this generally
                writeln("CHUNKED ENCODING, OH OH!");
                creq.writeBody(req.bodyReader);
            }
            
            //writeln("PROXY REQUEST HEADERS:");
            //pretty_print_headers(creq.headers);
            //writeln();
		}

		void handleClientResponse(scope HTTPClientResponse cres)
		{
			import vibe.utils.string;

            // We don't currently support HTTP/1.0 clients
			if (res.httpVersion == HTTPVersion.HTTP_1_0) {
                throw new HTTPStatusException(HTTPStatus.httpVersionNotSupported);
			}

            writeln("ORIGINAL RESPONSE:");
            pretty_print_headers(cres.headers);

            // TODO: Decide whether to cache this response

            // Copy relevant response headers
            res.statusCode = cres.statusCode;
			foreach (key, value; cres.headers) {
                // TODO: Other headers not to keep?
				if (icmp2(key, "Connection") != 0)
					res.headers[key] = value;
			}

            // If content length is specified, perform an almost raw copy of the response
			if ("Content-Length" in cres.headers) {
                auto bodySize = cres.headers["Content-Length"].to!size_t();

				if (res.isHeadResponse)
                    res.writeVoidBody();
                else if (bodySize == 0)
                    res.writeBody(cast(ubyte[])"", null);
				else
                {
                    cres.readRawBody((scope reader) {
                        res.writeRawBody(reader, bodySize);
                    });
                }
				assert(res.headerWritten);

                writeln("PROXY RESPONSE HEADERS:");
                pretty_print_headers(res.headers);
                writeln();

				return;
			}

            // No content length in headers

			// Handle empty response bodies
			if (req.method == HTTPMethod.HEAD || "Transfer-Encoding" !in cres.headers) {
				res.writeVoidBody();
                return;
			}
			
            writeln("NOT IMPLEMENTED");
            throw new HTTPStatusException(HTTPStatus.notImplemented);

            /*
			// fall back to a generic re-encoding of the response
			// copy all headers that may pass from upstream to client
			foreach (n, v; cres.headers) {
				if (n !in non_forward_headers_map)
					res.headers[n] = v;
			}
			if (res.isHeadResponse) res.writeVoidBody();
			else res.bodyWriter.write(cres.bodyReader);
            */
		}

		requestHTTP(rurl, &setupClientRequest, &handleClientResponse);
	}

	return &handleRequest;
}
