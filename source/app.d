import vibe.d;
import std.stdio;

shared static this()
{
    auto router = new URLRouter;
    router.any("*", proxyRequest());

	auto settings = new HTTPServerSettings;
	settings.port = 80;
    settings.options = HTTPServerOption.parseURL | HTTPServerOption.parseQueryString;

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
	static immutable string[] non_forward_headers = ["Content-Length", "Transfer-Encoding", "Content-Encoding", "Connection", "User-Agent"];
	static InetHeaderMap non_forward_headers_map;
	if (non_forward_headers_map.length == 0)
		foreach (n; non_forward_headers)
			non_forward_headers_map[n] = "";

	URL url;
	url.schema = "http";

	void handleRequest(scope HTTPServerRequest req, scope HTTPServerResponse res)
	{
		auto rurl = url;
        rurl.host = req.host;
        rurl.port = 80; // TODO: get from request somehow?
		rurl.localURI = req.requestURL;

		void setupClientRequest(scope HTTPClientRequest creq)
		{
            writeln("ORIGINAL REQUEST:");
            writefln("%s %s", req.method, req.requestURL);
            pretty_print_headers(req.headers);

			creq.method = req.method;
			creq.headers = req.headers.dup;
			//creq.headers["Connection"] = "keep-alive";
			if (auto pfh = "X-Forwarded-Host" !in creq.headers) creq.headers["X-Forwarded-Host"] = req.headers["Host"];
			if (auto pfp = "X-Forwarded-Proto" !in creq.headers) creq.headers["X-Forwarded-Proto"] = req.tls ? "https" : "http";
			if (auto pff = "X-Forwarded-For" in req.headers) creq.headers["X-Forwarded-For"] = *pff ~ ", " ~ req.peer;
			else creq.headers["X-Forwarded-For"] = req.peer;

            // If they provide a content length, use it. Otherwise use chunked stream encoding
            if ("Content-Length" in req.headers)
                creq.writeBody(req.bodyReader, req.headers["Content-Length"].to!size_t());
            else
            {
                if (req.bodyReader.empty)
                {
                    // Leave the body empty
                }
                else
                {
                    writeln("CHUNKED ENCODING, OH OH!");
                    creq.writeBody(req.bodyReader);
                }
            }
            
            writeln("PROXY REQUEST HEADERS:");
            pretty_print_headers(creq.headers);
            writeln();
		}

		void handleClientResponse(scope HTTPClientResponse cres)
		{
			import vibe.utils.string;

			// copy the response to the original requester
			res.statusCode = cres.statusCode;

            writeln("ORIGINAL RESPONSE:");
            pretty_print_headers(cres.headers);

			// special case for empty response bodies
			if ("Content-Length" !in cres.headers && "Transfer-Encoding" !in cres.headers || req.method == HTTPMethod.HEAD) {
                /*
				foreach (key, value; cres.headers) {
					if (icmp2(key, "Connection") != 0)
						res.headers[key] = value;
				}
				res.writeVoidBody();
                return;
                */
                writeln("NOT IMPLEMENTED");
                assert(false);
			}

			// enforce compatibility with HTTP/1.0 clients that do not support chunked encoding
			// (Squid and some other proxies)
			if (res.httpVersion == HTTPVersion.HTTP_1_0 && ("Transfer-Encoding" in cres.headers || "Content-Length" !in cres.headers)) {
                writeln("NOT IMPLEMENTED");
				assert(false);
			}

			// to perform a verbatim copy of the client response
			if ("Content-Length" in cres.headers) {
                auto bodySize = cres.headers["Content-Length"].to!size_t();

				if ("Content-Encoding" in res.headers) res.headers.remove("Content-Encoding");
				foreach (key, value; cres.headers) {
					if (icmp2(key, "Connection") != 0)
						res.headers[key] = value;
				}
				
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

            writeln("NOT IMPLEMENTED");
            assert(false);
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

/*
void proxy_no_cache(HTTPServerRequest client_req, HTTPServerResponse client_res)
{
    // TODO: assert some stuff, fallback
    assert(!client_req.tls);    
    auto proxy_req_url = "http://" ~ client_req.host ~ client_req.requestURL;

    writeln("Uncached request: " ~ proxy_req_url);

    auto client_ip_address = client_req.clientAddress.toAddressString();
    auto client_req_forwarded_field = client_req.headers.get("X-Forwarded-For", "");

    requestHTTP(proxy_req_url,
                (scope HTTPClientRequest proxy_req) {
                    proxy_req.method = client_req.method;
                    proxy_req.headers = client_req.headers;
                    
                    proxy_req.headers.remove("Accept");
                    proxy_req.headers.remove("Accept-Encoding");
                    proxy_req.headers.remove("Accept-Charset");

                    proxy_req.headers["X-Real-IP"] = client_ip_address;
                    proxy_req.headers["X-Forwarded-For"] =
                        client_req_forwarded_field.empty ? client_ip_address :
                        client_req_forwarded_field ~ ", " ~ client_ip_address;

                    writeln("CLIENT REQUEST HEADERS:");
                    pretty_print_headers(client_req.headers);
                    writeln("UPSTREAM REQUEST HEADERS:");
                    pretty_print_headers(proxy_req.headers);

                    proxy_req.writeBody(client_req.bodyReader);
                },
                (scope HTTPClientResponse proxy_res) {
                    writeln("UPSTREAM RESPONSE HEADERS:");
                    pretty_print_headers(proxy_res.headers);

                    client_res.headers = proxy_res.headers;
                    client_res.statusCode = proxy_res.statusCode;
                    client_res.statusPhrase = proxy_res.statusPhrase;

                    writeln("CLIENT RESPONSE HEADERS:");
                    pretty_print_headers(client_res.headers);

                    if (res.isHeadResponse)
                        res.writeVoidBody();
                    auto size = client_res.headers["Content-Length"].to!size_t();
                    proxy_res.readRawBody((scope input_stream) {
                        client_res.writeRawBody(input_stream, size);
                    });

                    // to perform a verbatim copy of the client response
                    if ("Content-Length" in client_res.headers) {
                        if ("Content-Encoding" in proxy_res.headers)
                            proxy_res.headers.remove("Content-Encoding");

                        foreach (key, value; client_res.headers) {
                            if (icmp2(key, "Connection") != 0)
                                proxy_res.headers[key] = value;
                        }

                        auto size = client_res.headers["Content-Length"].to!size_t();
                        if (proxy_res.isHeadResponse)
                            proxy_res.writeVoidBody();
                        else
                        {
                            client_res.readRawBody((scope reader) {
                                proxy_res.writeRawBody(reader, size);
                            });
                        }

                        assert(res.headerWritten);
                    }
                });
}
*/