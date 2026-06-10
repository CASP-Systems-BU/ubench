package wrappers

import (
	"context"
	"github.com/atlas/slowpoke/pkg/invoke"
	"github.com/atlas/slowpoke/pkg/utility"
	"github.com/goccy/go-json"
	"net/http"
	"io"
)

func Wrapper[ReqType interface{}, RespType interface{}](handler func(context.Context, *ReqType) *RespType) func(w http.ResponseWriter, r *http.Request) {
	return func(w http.ResponseWriter, r *http.Request) {
		// Carry the inbound request's headers (incl. b3/traceparent trace
		// context) in ctx so downstream invoke.Invoke calls propagate them and
		// Istio/Jaeger can stitch a multi-hop trace.
		ctx := invoke.WithIncomingHeaders(r.Context(), r.Header)
		input, err := io.ReadAll(r.Body)
		r.Body.Close()
		var req ReqType
		err = json.Unmarshal(input, &req)
		if err != nil {
			panic(err)
		}
		resp := handler(ctx, &req)
		utility.DumpJson(resp, w)
	}
}