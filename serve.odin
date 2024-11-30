package serve

// Core networking
import net "core:net"

// File system and OS interaction
import fmt "core:fmt"
import log "core:log"
import os "core:os"
import pfile "core:path/filepath"
import pslash "core:path/slashpath"

// Concurrency and timing
import sync "core:sync"
import time "core:time"

// Input/Output and runtime
import rn "base:runtime"
import "core:io"
import th "core:thread"

// Data encoding/decoding
import enc "core:encoding/ansi"
import base64 "core:encoding/base64"
import csv "core:encoding/csv"
import json "core:encoding/json"
import uuid "core:encoding/uuid"
import vint "core:encoding/varint"

// Image processing
import bmp "core:image/bmp"
import png "core:image/png"

// Text processing and manipulation
import ted "core:text/edit"
import i18n "core:text/i18n"
import tmatch "core:text/match"
import reg "core:text/regex"
import tscan "core:text/scanner"
import tab "core:text/table"

// Unicode handling
import utf_tool "core:unicode/tools"
import utf16 "core:unicode/utf16"
import utf8 "core:unicode/utf8"

// Core utilities and algorithms
import bytes "core:bytes"
import crypto "core:crypto"
import flags "core:flags"
import math "core:math"
import rand "core:math/rand"
import mem "core:mem"
import sort "core:sort"

import com "core:compress"
import gzip "core:compress/gzip"
import shoco "core:compress/shoco"
import zlib "core:compress/zlib"
import slice "core:slice"
import heap "core:slice/heap"

import str "core:strings"
import strc "core:strconv"

// C interop
import c "core:c"

// Buffered I/O
import buffio "core:bufio"

// Data structures and containers
import avl "core:container/avl"
import bitarr "core:container/bit_array"
import list "core:container/intrusive/list"
import lru "core:container/lru"
import pqueue "core:container/priority_queue"
import queue "core:container/queue"
import rbtree "core:container/rbtree"
import smallarr "core:container/small_array"
import topsort "core:container/topological_sort"

// Testing
import test "core:testing"

ctx: rn.Context

// Data structure for client handling
Client_Data :: struct {
	client: net.TCP_Socket,
	src:    net.Endpoint,
}

Http_Methods ::  enum {
    UNKNOWN,
    GET,
    POST,
    PUT,
    DELETE,
    PATCH,
    OPTIONS
}

Http_Request :: struct {
    method: Http_Methods,
    route: string,
    http_version: f32,
}

// Function for returning httpMethod from string
ParseHttpMethod :: proc(method: string) -> Http_Methods {
    switch method {
        case "GET": return .GET
        case "POST": return .POST
        case "PUT": return .PUT
        case "DELETE": return .DELETE
        case "PATCH": return .PATCH
        case "OPTIONS": return .OPTIONS
        case: return .UNKNOWN
    }
}

MimeTyping :: proc(name: string) -> string {
    // Make os.read_entire_file_from_filename_or_err instead of #load
    // to need file in directory instead of in binary
    typesFile, typesFileErr := os.read_entire_file_from_filename_or_err("mime_types.json")
    if typesFileErr != nil {
        log.error("Error reading MIME types file:", typesFileErr)
        return "application/octet-stream"
    }
    defer delete(typesFile)

    typesJson, typesErr := json.parse(typesFile)
    if typesErr != .None || typesJson == nil {
        log.error("Error parsing MIME types file:", typesErr)
        return "application/octet-stream"
    }
    defer json.destroy_value(typesJson)

    // Remove leading period if present
    ext := name
    if len(name) > 0 && name[0] == '.' {
        ext = name[1:]
    }

    array, ok := typesJson.(json.Array)
    if !ok {
        return "application/octet-stream"
    }

    for value in array {
        obj, ok := value.(json.Object)
        if !ok do continue

        extension, ok1 := obj["extension"].(json.String)
        if !ok1 do continue

        if extension == ext {
            mime_type, ok2 := obj["mime_type"].(json.String)
            if ok2 {
                return string(mime_type)
            }
        }
    }
    
    return "application/octet-stream"
}

CheckIfExists :: proc(path: string) -> (exists: bool, err: Maybe(string)) {
    // Remove leading slash for local path resolution
    clean_path := path
    if len(clean_path) > 0 && clean_path[0] == '/' {
        clean_path = clean_path[1:]
    }
    
    // Normalize path to handle different path separators
    normalizedPath := pfile.clean(clean_path)
    
    // Split path into components
    separator := "/"
    when ODIN_OS == .Windows {
        separator = "\\"
    }

    steps := str.split(normalizedPath, separator)
    defer delete(steps)
    
    // Check path depth
    if len(steps) > 11 {
        return false, "Path exceeds maximum allowed depth of 10 subdirectories"
    }
    
    // Check for parent directory traversal
    for step in steps {
        if step == ".." {
            return false, "Parent directory traversal not allowed"
        }
    }
    
    // Handle root path special case
    if normalizedPath == "" || normalizedPath == "/" {
        if os.exists("index.html") {
            return true, nil
        }
        return false, "Root index.html not found"
    }
    
    // Build path progressively and check at each step
    currentPath := ""
    for i := 0; i < len(steps); i += 1 {
        if i > 0 {
            currentPath = str.join({currentPath, steps[i]}, separator)
        } else {
            currentPath = steps[i]
        }
        
        // Ensure path exists and is accessible
        if !os.exists(currentPath) {
            return false, "Path does not exist"
        }
        
        // Check if current path is a file
        isFile := os.is_file(currentPath)
        if isFile {
            if i == len(steps) - 1 {
                return true, nil // Found the target file
            } else {
                return false, "Intermediate path component is a file"
            }
        }
        
        // If it's a directory and we're at the end, check for index.html
        isDir := os.is_dir(currentPath)
        if isDir && i == len(steps) - 1 {
            // Try both with and without separator for index.html
            index_path := str.join({currentPath, "index.html"}, separator)
            if os.exists(index_path) && os.is_file(index_path) {
                return true, nil
            }
        }
    }
    
    return false, "Path does not lead to a file or directory with index.html"
}


ServeFile :: proc(path: string) -> (content: []byte, ok: bool) {
    // Remove leading slash for local path resolution
    separator := "/"
    when ODIN_OS == .Windows {
        separator = "\\"
    }

    cleanPath := path
    if len(cleanPath) > 0 && cleanPath[0] == '/' {
        cleanPath = cleanPath[1:]
    }
    
    // If path is empty or "/", serve index.html
    if cleanPath == "" || cleanPath == "/" {
        cleanPath = "index.html"
    }
    
    // If path is a directory, append index.html
    if os.is_dir(cleanPath) {
        cleanPath = str.join({cleanPath, "index.html"}, separator)
    }
    
    file, fileErr := os.read_entire_file_from_filename_or_err(cleanPath)
    if fileErr != nil {
        log.error("Error reading file:", fileErr)
        return nil, false
    }
    return file, true
}

// Function to handle individual client requests
HandleClient :: proc(t: th.Task) {
    context = ctx

    clientData := cast(^Client_Data)t.data
    if clientData == nil {
        log.error("Invalid client data")
        return
    }

    defer net.close(clientData.client) 
    defer free(clientData)

    log.debug("Processing client from", net.endpoint_to_string(clientData.src))

    // Read request headers
    reqBuff: [4096]u8
    reqBytes, readErr := net.recv_tcp(clientData.client, reqBuff[:])
    if readErr != nil {
        log.error("Error reading request:", readErr)
        return
    }

    req := string(reqBuff[:reqBytes])
    log.debug("Received request:", req)

    reqFormatted := str.split(req, "\n")[0]
    
    requestHttp := Http_Request{}
    for &val, idx in str.split(reqFormatted, " ") {
        if idx == 0 {
            requestHttp.method = Http_Methods(ParseHttpMethod(val))
            if requestHttp.method == .UNKNOWN {
                log.error("Unknown HTTP method:", val)
                return
            }
        } else if idx == 1 {
            if str.ends_with(val, "?") {
                val = val[:len(val)-1]
            }
            if str.starts_with(val, "&") {
                val = val[:len(val)-1]
            }
            if str.ends_with(val, "/") && val != "/" {
                val = val[:len(val)-1]
            }
            if val == "" {
                val = "/"
            }
            requestHttp.route = val
        } else if idx == 2 {
            httpVer, httpVerErr := strc.parse_f32(str.split(val, "HTTP/")[1])
            if httpVerErr {
                log.error("Error parsing HTTP version:", httpVerErr)
                return
            }
            requestHttp.http_version = httpVer
        }
    }

    log.debug("Request method:", requestHttp.method)
    log.debug("Request route:", requestHttp.route)
    log.debug("HTTP version:", requestHttp.http_version)

    exist, existErr := CheckIfExists(requestHttp.route)
    if existErr != nil {
        log.error("Error checking if file exists:", requestHttp.route, existErr)
        // Send 404 response
        error_response := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        net.send_tcp(clientData.client, transmute([]u8)error_response)
        return
    }
    
    log.info("Exists?:", requestHttp.route, exist)
    if !exist {
        log.error("File does not exist:", requestHttp.route)
        // Send 404 response
        errRes := "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\n\r\n"
        net.send_tcp(clientData.client, transmute([]u8)errRes)
        return
    }

    // Get the content for the specific route
    content, contentOk := ServeFile(requestHttp.route)
    if !contentOk {
        // Send 500 response
        errRes := "HTTP/1.1 500 Internal Server Error\r\nContent-Length: 0\r\n\r\n"
        net.send_tcp(clientData.client, transmute([]u8)errRes)
        return
    }
    defer delete(content)

    
    // Get the file extension
    extension: string = ""
    #reverse for ext, idx in str.split(requestHttp.route, "") {
        if ext == "." {
            extension = requestHttp.route[idx+1:]
            break;
        }
    }
    
    if extension == "" {
        extension = "text/html"
    } else {
        extension = str.to_lower(extension)
        extension = MimeTyping(extension)
    }

    // Build and send response with the correct content
    b := str.builder_make()
    defer str.builder_destroy(&b)

    // Build the response headers
    str.write_string(&b, "HTTP/1.1 200 OK\r\n")
    fmt.sbprintf(&b, "Content-Type: %v; charset=utf-8\r\n", extension)
    fmt.sbprintf(&b, "Content-Length: %d\r\n", len(content))
    str.write_string(&b, "Connection: close\r\n\r\n")
    str.write_bytes(&b, content)

    // Get the complete response
    res := str.to_string(b)
    sentBytes := 0
    totalBytes := len(res)
    responseData := transmute([]u8)res

    for sentBytes < totalBytes {
        writeCount, writeErr := net.send_tcp(clientData.client, responseData[sentBytes:])
        if writeErr != nil {
            log.error("Error writing response:", writeErr)
            return
        }
        sentBytes += writeCount
    }

    log.debug("Successfully sent", sentBytes, "bytes to client")
}

// Main server setup
main :: proc() {

    fileLoggerHandle, fileLoggerErr := os.open(
        "./server.log",
        os.O_WRONLY | os.O_CREATE | os.O_APPEND | os.O_ASYNC | os.O_NONBLOCK,
        0o644,
    )
    if fileLoggerErr != nil {
        fmt.println("Failed to open log file:", fileLoggerErr)
        return
    }
    defer os.close(fileLoggerHandle)

    fileLogger := log.create_file_logger(fileLoggerHandle, .Info)
    consoleLogger := log.create_console_logger(.Info)
    logger := log.create_multi_logger(fileLogger, consoleLogger)
    logger.options = {
        .Level,
        .Long_File_Path,
        .Line,
        .Procedure,
        .Terminal_Color,
        .Time,
        .Date
    }
    
    context.logger = logger
    ctx = context

    defer log.destroy_file_logger(fileLogger)
    defer log.destroy_console_logger(consoleLogger)
    defer log.destroy_multi_logger(logger)


	endpoint := net.Endpoint{}
	endpoint.address = net.IP4_Address{127, 0, 0, 1}
	endpoint.port = 8080

	socket, socketErr := net.listen_tcp(endpoint, 1024)
	if socketErr != nil {
		log.fatal("Error listening on port 8080:", socketErr)
		return
	}
	defer net.close(socket)

	log.debug("Server listening on port 8080")
    log.debug("SERVER LISTENING ON PORT 8080")


    
	pool: th.Pool
	th.pool_init(&pool, context.allocator, 4)
	defer th.pool_destroy(&pool)
	th.pool_start(&pool)


    userIdx: int = 0
	MainLoop(&socket, &pool, &userIdx)
}

MainLoop :: proc(socket: ^net.TCP_Socket, pool: ^th.Pool, idx: ^int) {
    context = ctx

    for {
		client, src, acceptErr := net.accept_tcp(socket^)
		if acceptErr != nil {
			log.error("Error accepting client:", acceptErr)
			continue
		}
        log.debug("CLIENT: ", client)
        log.debug("SOURCE: ", src)

		clientData := new(Client_Data)
		if clientData == nil {
			log.error("Failed to allocate client data")
			net.close(client)
			continue
		}

		clientData.client = client
		clientData.src = src

        log.debug("CLIENT DATA: ", clientData^)

		task := th.Task {
			data      = clientData,
			procedure = HandleClient,
			allocator = context.allocator,
            user_index = idx^
        }
        idx^ += 1
        if(idx^ > 10) {
            idx^ = 0
        }
        log.debug("TASK: ", &task)

		th.pool_add_task(pool, context.allocator, task.procedure, task.data)
	}	
}
