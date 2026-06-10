package invoke

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"sync"
	"time"

	pb "github.com/atlas/slowpoke/pkg/pb"
	"github.com/atlas/slowpoke/pkg/utility"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
        "google.golang.org/grpc/status"
	"google.golang.org/grpc/metadata"
)


var (
	grpcConns    map[string]*grpc.ClientConn = make(map[string]*grpc.ClientConn)
	grpcConnLock sync.RWMutex
)

var HTTPClient = &http.Client{
	Transport: &http.Transport{MaxConnsPerHost: 0, MaxIdleConnsPerHost: 500, MaxIdleConns: 500},
	Timeout:   60 * time.Second,
}

// Distributed-tracing context headers. Istio/Envoy injects these on a single
// hop, but to stitch a multi-hop trace in Jaeger the application must forward
// them from each inbound request to its outbound calls.
var tracePropagationHeaders = []string{
	"x-request-id",
	"x-b3-traceid", "x-b3-spanid", "x-b3-parentspanid", "x-b3-sampled", "x-b3-flags",
	"x-ot-span-context",
	"traceparent", "tracestate", "b3",
}

type ctxKey string

const incomingHeadersKey ctxKey = "incomingHeaders"

// WithIncomingHeaders stashes the inbound request's headers in ctx. wrappers.Wrapper
// calls this so every downstream Invoke(ctx, ...) can propagate the trace headers
// above without changing the 50+ call sites that pass an empty http.Request{}.
func WithIncomingHeaders(ctx context.Context, h http.Header) context.Context {
	return context.WithValue(ctx, incomingHeadersKey, h)
}

func incomingHeaders(ctx context.Context) http.Header {
	if h, ok := ctx.Value(incomingHeadersKey).(http.Header); ok {
		return h
	}
	return nil
}

func performRequest[T interface{}](ctx context.Context, req *http.Request, res *T, app string, method string, argBytes []byte) {
	resp, err := HTTPClient.Do(req)
	if err != nil {
		panic(err)
	}
	utility.Assert(resp.StatusCode == http.StatusOK)
	defer resp.Body.Close()
	utility.ParseJson(resp.Body, res)
}

func Invoke[T interface{}](ctx context.Context, app string, method string, input interface{}, request http.Request) T {
	buf, err := json.Marshal(input)
	if err != nil {
		panic(err)
	}
	var res T
	// Use kubernete native DNS addr
	url := fmt.Sprintf("http://%s.%s.svc.cluster.local:%s/%s", app, "default", "80", method)
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(buf))
	if err != nil {
		panic(err)
	}
	// Propagate distributed-tracing headers from the inbound request so Istio's
	// sidecars can stitch a multi-hop trace in Jaeger. Source: the inbound
	// headers stashed in ctx by wrappers.Wrapper; fall back to the explicit
	// request arg for any caller that passes a real http.Request.
	src := incomingHeaders(ctx)
	if src == nil {
		src = request.Header
	}
	for _, h := range tracePropagationHeaders {
		if v := src.Get(h); v != "" {
			req.Header.Set(h, v)
		}
	}
	performRequest[T](ctx, req, &res, app, method, buf)
	return res
}

func InitGRPCConn(app string) *grpc.ClientConn {
	conn, err := grpc.Dial(fmt.Sprintf("%s.default.svc.cluster.local:%s", app, "80"), grpc.WithInsecure())
	if err != nil {
		panic(err)
	}
	return conn
}

func requestIDFromContext(ctx context.Context) (string, bool) {
	md, ok := metadata.FromIncomingContext(ctx)
	if !ok {
		return "", false
	}
	vals := md.Get("x-request-id")
	if len(vals) == 0 {
		return "", false
	}
	return vals[0], true
}

func InvokeGRPC(ctx context.Context, app string, method string, input interface{}) string {
	var grpcConn *grpc.ClientConn

	grpcConnLock.RLock()
	if _, ok := grpcConns[app]; ok {
		grpcConn = grpcConns[app]
	}
	grpcConnLock.RUnlock()

	if grpcConn == nil {
		grpcConnLock.Lock()
		if _, ok := grpcConns[app]; !ok {
			grpcConns[app] = InitGRPCConn(app)
		}
		grpcConn = grpcConns[app]
		grpcConnLock.Unlock()
	}

	// // Extract x-request-id from incoming gRPC context
	// if rid, ok := requestIDFromContext(ctx); ok {
	// 	ctx = metadata.AppendToOutgoingContext(ctx, "x-request-id", rid)
	// }

	if rid, ok := requestIDFromContext(ctx); ok {
		outMD, _ := metadata.FromOutgoingContext(ctx)
		outMD = outMD.Copy()
		outMD.Set("x-request-id", rid)
		ctx = metadata.NewOutgoingContext(ctx, outMD)
	}

	client := pb.NewSimpleClient(grpcConn)
	resp_, err := client.SimpleRPC(ctx, &pb.SimpleRequest{Endpoint: method})
        if err != nil {
            // Treat expected cancellations/timeouts as non-fatal
            if st, ok := status.FromError(err); ok {
                switch st.Code() {
                case codes.Canceled, codes.DeadlineExceeded:
                    return ""
                }
            }
            panic(err)
        }
	return resp_.Resp
}
