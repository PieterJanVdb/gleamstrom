import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang
import gleam/erlang/process.{type Subject}
import gleam/function
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/yielder

pub type RPCRequest {
  RPCRequest(kind: String, body: Dynamic, msg_id: Int)
}

pub type RPCReply {
  RPCReply(kind: String, body: Dynamic, msg_id: Int, in_reply_to: Int)
}

pub type InitRequest {
  InitRequest(msg_id: Int, node_id: String, node_ids: List(String))
}

pub type MessageBody {
  InitRequestBody(InitRequest)
  RPCRequestBody(RPCRequest)
  RPCReplyBody(RPCReply)
}

pub type Message {
  Message(src: String, dest: String, body: MessageBody)
}

pub type RPCBody =
  List(#(String, json.Json))

pub type HandlerResult {
  HandlerReply(kind: String, body: RPCBody)
  HandlerNoReply
  HandlerError(code: Int, text: String)
}

pub type RPCReplyHandler(a) =
  fn(RPCReply, a, Message, Node(a)) -> #(HandlerResult, a)

pub type RPCRequestHandler(a) =
  fn(RPCRequest, a, Message, Node(a)) -> #(HandlerResult, a)

fn body_decoder(body: Dynamic) {
  use kind <- decode.field("type", decode.string)

  case kind {
    "init" -> {
      use msg_id <- decode.field("msg_id", decode.int)
      use node_id <- decode.field("node_id", decode.string)
      use node_ids <- decode.field("node_ids", decode.list(decode.string))

      decode.success(InitRequestBody(InitRequest(msg_id:, node_id:, node_ids:)))
    }
    _ -> {
      use msg_id <- decode.field("msg_id", decode.int)
      use in_reply_to <- decode.optional_field(
        "in_reply_to",
        None,
        decode.optional(decode.int),
      )

      case in_reply_to {
        Some(in_reply_to) ->
          decode.success(
            RPCReplyBody(RPCReply(kind:, msg_id:, in_reply_to:, body:)),
          )
        None ->
          decode.success(RPCRequestBody(RPCRequest(kind:, msg_id:, body:)))
      }
    }
  }
}

fn message_decoder() {
  use src <- decode.field("src", decode.string)
  use dest <- decode.field("dest", decode.string)
  use raw_body <- decode.field("body", decode.dynamic)
  use body <- decode.field("body", body_decoder(raw_body))

  decode.success(Message(src:, dest:, body:))
}

fn handle_init_request(
  actor_state: NodeState(a),
  msg: Message,
  body: InitRequest,
) {
  reply(node: actor_state.self, dest: msg.src, in_reply_to: body.msg_id, body: [
    #("type", json.string("init_ok")),
  ])

  NodeState(
    ..actor_state,
    node_id: Some(body.node_id),
    node_ids: Some(body.node_ids),
  )
}

fn handle_result(
  actor_state: NodeState(a),
  msg: Message,
  in_reply_to: Int,
  handler_result: HandlerResult,
) {
  case handler_result {
    HandlerNoReply -> Nil
    HandlerReply(kind, body) -> {
      let body = [#("type", json.string(kind)), ..body]
      reply(node: actor_state.self, dest: msg.src, in_reply_to:, body:)
    }
    HandlerError(code, text) ->
      error(node: actor_state.self, dest: msg.src, in_reply_to:, code:, text:)
  }
}

fn handle_request(actor_state: NodeState(a), msg: Message, body: RPCRequest) {
  let #(handler_result, new_app_state) =
    actor_state.request_handler(
      body,
      actor_state.app_state,
      msg,
      actor_state.self,
    )

  handle_result(actor_state, msg, body.msg_id, handler_result)

  NodeState(..actor_state, app_state: new_app_state)
}

fn handle_reply(actor_state: NodeState(a), msg: Message, body: RPCReply) {
  case list.key_pop(actor_state.reply_handlers, body.in_reply_to) {
    Ok(#(reply_handler, next_reply_handlers)) -> {
      let #(handler_result, new_app_state) =
        reply_handler(body, actor_state.app_state, msg, actor_state.self)

      handle_result(actor_state, msg, body.msg_id, handler_result)

      NodeState(
        ..actor_state,
        app_state: new_app_state,
        reply_handlers: next_reply_handlers,
      )
    }
    Error(_) -> {
      io.println_error("No reply handler found for " <> string.inspect(body))
      actor_state
    }
  }
}

fn process_incoming_message(actor_state: NodeState(a), msg_string: String) {
  use msg <- result.try(json.parse(from: msg_string, using: message_decoder()))

  let next_actor_state = case msg.body {
    InitRequestBody(body) -> handle_init_request(actor_state, msg, body)
    RPCReplyBody(body) -> handle_reply(actor_state, msg, body)
    RPCRequestBody(body) -> handle_request(actor_state, msg, body)
  }

  Ok(next_actor_state)
}

fn process_outgoing_request(
  actor_state: NodeState(a),
  dest: String,
  body: RPCBody,
  reply_handler: RPCReplyHandler(a),
) {
  let msg_id = actor_state.next_msg_id
  let next_actor_state = process_outgoing_message(actor_state, dest, body)

  let reply_handlers = [
    #(msg_id, reply_handler),
    ..next_actor_state.reply_handlers
  ]

  NodeState(..next_actor_state, reply_handlers:)
}

fn process_outgoing_message(
  actor_state: NodeState(a),
  dest: String,
  body: RPCBody,
) {
  // We should only be processing outgoing messages after init
  let assert Some(node_id) = actor_state.node_id

  let body = [#("msg_id", json.int(actor_state.next_msg_id)), ..body]
  let msg_json =
    json.object([
      #("src", json.string(node_id)),
      #("dest", json.string(dest)),
      #("body", json.object(body)),
    ])
    |> json.to_string()

  // Send to maelstrom
  io.println(msg_json)

  NodeState(..actor_state, next_msg_id: actor_state.next_msg_id + 1)
}

pub type Node(a) =
  Subject(NodeMessage(a))

pub type NodeMessage(a) {
  IncomingMessage(String)
  OutgoingRequest(
    dest: String,
    body: RPCBody,
    reply_handler: RPCReplyHandler(a),
  )
  OutgoingMessage(dest: String, body: RPCBody)
}

pub type NodeError {
  StartError(actor.StartError)
}

pub type RPCReplyHandlerMap(a) =
  List(#(Int, RPCReplyHandler(a)))

type NodeState(a) {
  NodeState(
    self: Node(a),
    node_id: Option(String),
    node_ids: Option(List(String)),
    next_msg_id: Int,
    app_state: a,
    reply_handlers: RPCReplyHandlerMap(a),
    request_handler: RPCRequestHandler(a),
  )
}

fn node_message_loop(actor_message: NodeMessage(a), actor_state: NodeState(a)) {
  case actor_message {
    IncomingMessage(msg_string) -> {
      case process_incoming_message(actor_state, msg_string) {
        Ok(new_actor_state) -> new_actor_state
        Error(err) -> {
          io.println_error(
            "Error handling incoming msg ("
            <> msg_string
            <> "): "
            <> string.inspect(err),
          )
          actor_state
        }
      }
      |> actor.continue
    }

    OutgoingRequest(dest, body, reply_handler) -> {
      process_outgoing_request(actor_state, dest, body, reply_handler)
      |> actor.continue
    }

    OutgoingMessage(dest, body) -> {
      process_outgoing_message(actor_state, dest, body)
      |> actor.continue
    }
  }
}

fn listen_to_stdin(node: Node(a)) {
  yielder.repeatedly(fn() { erlang.get_line("") })
  |> yielder.take_while(result.is_ok)
  |> yielder.each(fn(res) {
    let assert Ok(line) = res
    actor.send(node, IncomingMessage(line))
  })
}

pub fn start_node(
  app_state app_state: a,
  request_handler request_handler: RPCRequestHandler(a),
) {
  let spec =
    actor.Spec(
      init: fn() {
        let self = process.new_subject()
        let selector =
          process.new_selector()
          |> process.selecting(self, function.identity)

        actor.Ready(
          state: NodeState(
            self:,
            app_state:,
            node_id: None,
            node_ids: None,
            next_msg_id: 0,
            request_handler:,
            reply_handlers: [],
          ),
          selector:,
        )
      },
      init_timeout: 100,
      loop: node_message_loop,
    )

  use node <- result.try(
    actor.start_spec(spec)
    |> result.map_error(StartError),
  )

  listen_to_stdin(node) |> Ok()
}

pub fn message(node node: Node(a), dest dest: String, body body: RPCBody) {
  actor.send(node, OutgoingMessage(dest, body))
}

pub fn reply(
  node node: Node(a),
  dest dest: String,
  in_reply_to in_reply_to: Int,
  body body: RPCBody,
) {
  let body = [#("in_reply_to", json.int(in_reply_to)), ..body]
  message(node:, dest:, body:)
}

pub fn error(
  node node: Node(a),
  dest dest: String,
  in_reply_to in_reply_to: Int,
  code code: Int,
  text text: String,
) {
  let body = [
    #("type", json.string("error")),
    #("in_reply_to", json.int(in_reply_to)),
    #("code", json.int(code)),
    #("text", json.string(text)),
  ]
  message(node:, dest:, body:)
}

pub fn request(
  node node: Node(a),
  dest dest: String,
  body body: RPCBody,
  reply_handler reply_handler: RPCReplyHandler(a),
) {
  actor.send(node, OutgoingRequest(dest, body, reply_handler))
}
