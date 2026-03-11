/**
 * JSON-RPC 2.0 message type definitions.
 */
export interface JsonRpcRequest {
    readonly jsonrpc: "2.0";
    id: number;
    method: string;
    params?: unknown;
}
export interface JsonRpcNotification {
    readonly jsonrpc: "2.0";
    method: string;
    params?: unknown;
}
export interface JsonRpcResponse {
    readonly jsonrpc: "2.0";
    id: number;
    result?: unknown;
    error?: JsonRpcErrorData;
}
export interface JsonRpcErrorData {
    code: number;
    message: string;
    data?: unknown;
}
export type JsonRpcMessage = JsonRpcRequest | JsonRpcNotification | JsonRpcResponse;
/** Standard JSON-RPC 2.0 error codes. */
export declare const ErrorCodes: {
    readonly PARSE_ERROR: -32700;
    readonly INVALID_REQUEST: -32600;
    readonly METHOD_NOT_FOUND: -32601;
    readonly INVALID_PARAMS: -32602;
    readonly INTERNAL_ERROR: -32603;
};
//# sourceMappingURL=types.d.ts.map