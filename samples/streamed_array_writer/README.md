# Streamed Array Writer

Explicit, developer-driven streaming of a JSON array with **`TMVCJSONArrayWriter`**
(unit `MVCFramework.SSE.Writer`).

The action opens `[`, pushes one JSON value per iteration straight to the
socket, and closes `]`. Between iterations only the running element lives in
memory, so **server RAM stays flat** no matter how many elements are emitted.
The client receives one ordinary, valid JSON array.

## The point: the writer is source-agnostic

`Send(const AJSONValue: string)` takes **any complete JSON value**. It doesn't
know or care where the value came from, so the *same* writer streams three very
different sources:

| Route | Source | Notes |
|-------|--------|-------|
| `GET /stream/dataset` | forward-only FireDAC cursor (`fmOnDemand` + `Unidirectional`), raw record | neither the dataset nor the JSON is ever fully in memory; JSON uses the raw column names |
| `GET /stream/dbobjects` | the same cursor, each row mapped to a `TPerson` | hydrate one entity per row, serialize it, discard it — one row + one object + one JSON value at a time; JSON follows the object's rules |
| `GET /stream/objectlist` | a `TObjectList<TPerson>` you already hold | the list is in memory (you built it); the JSON payload is **not** |
| `GET /stream/datasetfunc` | a functional action that just **returns** a `TDataSet` | the zero-code path: the framework serializes it; see the caveat below |
| `GET /stream/enumeration` | a lazy `TEnumerable<TPerson>` reading a file line by line | the file is never loaded whole; at most one `TPerson` exists at a time — the realistic "stream objects read from a file or DB cursor" case |
| `GET /stream/datasetstreamed` | a functional action that returns `TMVCStreamedResponse` (via `StreamDataSet`) | declarative like `/datasetfunc` but streams incrementally with flat framework RAM and no `Content-Length`. Indy Direct: `Transfer-Encoding: chunked` + keep-alive. HTTP.sys: close-delimited body (no keep-alive). Not on WebBroker (raises 501). |

The enumeration source (`PeopleSourcesU.pas`) is a plain `TEnumerable<TPerson>` /
`TEnumerator<TPerson>` pair backed by a `TStreamReader`. It yields one `TPerson`
per line and frees the previous one as the cursor advances, so a regular
`for p in source do` loop streams a 200k-line file with flat memory. Swap the
file reader for a DB cursor or a socket and nothing else changes.

Per element you pick the matching serializer call:
`Serializer.SerializeDataSetRecord(qry)` for a dataset row,
`Serializer.SerializeObject(obj)` for an object.

## Run

```
StreamedArrayWriterSample.exe
```

On first launch it creates `people.db` (SQLite, 200k rows) and `people_feed.csv`
(200k lines, the feed for the enumeration demo), then listens on
**http://localhost:8991** (Indy Direct).

```
# absence of Content-Length proves the body is streamed, not buffered
curl -s -D - http://localhost:8991/stream/dataset      -o out.json
curl -s -D - http://localhost:8991/stream/objectlist   -o out.json
curl -s -D - http://localhost:8991/stream/enumeration  -o out.json
# this one DOES have Content-Length (see caveat below)
curl -s -D - http://localhost:8991/stream/datasetfunc      -o out.json
# declarative + chunked: no Content-Length, keep-alive, flat framework RAM
curl -s -D - http://localhost:8991/stream/datasetstreamed  -o out.json
```

## Explicit writer vs. returning a `TDataSet`

`/stream/datasetfunc` is a plain functional action: `function GetPeopleDataSet:
TDataSet; begin Result := ...; end;`. You write **no streaming code** and the
framework serializes the dataset for you. But it does **not** stream to the
socket record by record — it is a different mechanism:

| | functional action `: TDataSet` | `TMVCStreamedResponse` via `StreamDataSet` | the four `TMVCJSONArrayWriter` endpoints |
|---|---|---|---|
| Who serializes | the framework (`TMVCStreamingJsonSerializer`) | the framework | you, one value per `Send()` |
| JSON DOM built | no (rows → bytes directly) | no | no |
| DB-side RAM | bounded (the cursor is unidirectional) | bounded | bounded |
| **Framework-side RAM** | **the whole JSON payload** (a memory stream) | **one record** | **one record** |
| `Content-Length` | **yes** (size is known before sending) | no (chunked on Indy, close-delimited on HTTP.sys) | no (`Connection: close`) |
| Backends | all (WebBroker / Indy / HTTP.sys) | Indy Direct + HTTP.sys | Indy-based only |
| Code to write | zero | zero | you drive the loop |

So returning a `TDataSet` is "streaming **serialization** into a buffer", not
"streaming to the socket". It is the right default for moderate result sets
(works everywhere, has `Content-Length`, no code). Reach for the explicit
writer when you must also keep **framework**-side RAM flat (very large or
unbounded results) or when the source is not a single dataset (object lists,
generators, merged sources, custom per-element logic).

## Relation to `streaming_json_dataset`

The sibling `streaming_json_dataset` sample focuses entirely on that implicit
return-a-`TDataSet` path (here it is just `/stream/datasetfunc`). This sample
adds the four explicit-writer variants alongside it for contrast.

## Requirements

The four explicit-writer endpoints take over the raw socket, so they require an
**Indy-based backend** (Indy Direct, or WebBroker hosted by
`TIdHTTPWebBrokerBridge`); they cannot stream over an HTTP.sys socket.
`/stream/datasetfunc` has no such restriction — it goes through the normal
response path and works on every backend.
