/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The window server's wire protocol (docs/design/WINDOWSERVER.md): fixed
 * headers and bodies over a Unix-domain stream socket; window buffers are
 * shared memory passed as file descriptors. Shared by the server and the
 * client library in CoreGraphics.
 */
#ifndef FINCH_WS_PROTOCOL_H
#define FINCH_WS_PROTOCOL_H

#include <stdint.h>

#define FWS_SOCKET_DEFAULT "/tmp/finch-windowserver"
#define FWS_SOCKET_ENV "FINCH_WINDOWSERVER_SOCKET"
#define FWS_PROTOCOL_VERSION 1

enum {
    /* client -> server */
    FWS_HELLO = 1,
    FWS_CREATE_WINDOW,
    FWS_DESTROY_WINDOW,
    FWS_SET_FRAME,      /* moving keeps the buffer; resizing replies with a new one */
    FWS_ORDER,
    FWS_SET_LEVEL,
    FWS_SET_ALPHA,
    FWS_SET_FLAGS,
    FWS_SET_TITLE,
    FWS_FLUSH,
    FWS_SET_CURSOR,
    FWS_WARP_CURSOR,
    FWS_SET_CURSOR_VISIBLE,
    FWS_MAKE_KEY,
    FWS_WINDOW_LIST,
    FWS_POST_EVENT,
    FWS_SNAPSHOT,       /* the composited screen, for tests: replies an FWSBuffer and its fd */
    /* server -> client */
    FWS_REPLY = 100,
    FWS_EVENT,
    FWS_WINDOW_MOVED,
    FWS_ACTIVATED,
    FWS_DISPLAY_CHANGED,
};

typedef struct {
    uint32_t type;
    uint32_t size;    /* of the body that follows */
    uint32_t serial;  /* a reply carries its request's */
    uint32_t window;  /* the window concerned, or 0 */
} FWSHeader;

typedef struct {
    double x, y, width, height;
} FWSRect;

/* FWS_HELLO */
typedef struct {
    uint32_t version;
    int32_t pid;
    char name[64];
} FWSHello;

/* reply to FWS_HELLO, and FWS_DISPLAY_CHANGED */
typedef struct {
    uint32_t connection;
    uint32_t display;          /* the main display's ID */
    double width, height;      /* points */
    double scale;              /* pixels per point */
    double refresh;            /* Hz */
} FWSDisplayInfo;

enum {
    FWS_WINDOW_OPAQUE = 1 << 0,
    FWS_WINDOW_SHADOW = 1 << 1,
    FWS_WINDOW_IGNORES_MOUSE = 1 << 2,
    FWS_WINDOW_SHARED = 1 << 3,    /* listed for other apps */
};

/* FWS_CREATE_WINDOW, FWS_SET_FRAME */
typedef struct {
    FWSRect frame;    /* global display coordinates, points */
    int32_t level;    /* CGWindowLevel */
    uint32_t flags;
} FWSWindowSpec;

/* reply to FWS_CREATE_WINDOW, or to FWS_SET_FRAME with a new size; one fd is passed */
typedef struct {
    uint32_t window;
    uint32_t pixel_width, pixel_height;
    uint32_t bytes_per_row;
    uint64_t length;
} FWSBuffer;

enum { FWS_ORDER_OUT = 0, FWS_ORDER_ABOVE = 1, FWS_ORDER_BELOW = -1 };

/* FWS_ORDER */
typedef struct {
    int32_t mode;
    uint32_t relative_to;  /* 0: all windows of the level */
} FWSOrder;

/* FWS_SET_LEVEL, FWS_SET_FLAGS */
typedef struct {
    int32_t value;
} FWSInt;

/* FWS_SET_ALPHA */
typedef struct {
    double alpha;
} FWSDouble;

/* FWS_SET_TITLE: UTF-8 follows */

/* FWS_FLUSH: the damaged area, in points relative to the window (empty: all) */
typedef struct {
    FWSRect rect;
} FWSFlush;

/* FWS_SET_CURSOR */
enum { FWS_CURSOR_ARROW, FWS_CURSOR_IBEAM, FWS_CURSOR_POINTING_HAND, FWS_CURSOR_RESIZE_LEFT_RIGHT,
       FWS_CURSOR_RESIZE_UP_DOWN, FWS_CURSOR_CROSSHAIR, FWS_CURSOR_CLOSED_HAND, FWS_CURSOR_OPEN_HAND,
       FWS_CURSOR_IMAGE };
typedef struct {
    int32_t shape;
    double hot_x, hot_y;
    uint32_t pixel_width, pixel_height;  /* FWS_CURSOR_IMAGE: BGRA premultiplied pixels follow */
} FWSCursor;

/* FWS_WARP_CURSOR */
typedef struct {
    double x, y;
} FWSPoint;

/* reply to FWS_WINDOW_LIST: a count, then the entries, front to back */
typedef struct {
    uint32_t window;
    int32_t pid;
    int32_t level;
    uint32_t flags;
    uint32_t on_screen;
    double alpha;
    FWSRect frame;
    char owner[64];
    char title[128];
} FWSWindowInfo;

/* event types: CGEventType's values */
enum {
    FWS_EVENT_LEFT_DOWN = 1, FWS_EVENT_LEFT_UP = 2, FWS_EVENT_RIGHT_DOWN = 3, FWS_EVENT_RIGHT_UP = 4,
    FWS_EVENT_MOUSE_MOVED = 5, FWS_EVENT_LEFT_DRAGGED = 6, FWS_EVENT_RIGHT_DRAGGED = 7,
    FWS_EVENT_KEY_DOWN = 10, FWS_EVENT_KEY_UP = 11, FWS_EVENT_FLAGS_CHANGED = 12,
    FWS_EVENT_SCROLL = 22, FWS_EVENT_OTHER_DOWN = 25, FWS_EVENT_OTHER_UP = 26, FWS_EVENT_OTHER_DRAGGED = 27,
    /* queued by the client library, not sent by the server */
    FWS_EVENT_APP_ACTIVATED = 1000,    /* FWS_ACTIVATED with active 1 */
    FWS_EVENT_APP_DEACTIVATED = 1001,  /* FWS_ACTIVATED with active 0 */
    FWS_EVENT_WINDOW_MOVED = 1002,     /* FWS_WINDOW_MOVED: the new frame in x, y, delta_x (width), delta_y (height) */
};

/* FWS_EVENT, FWS_POST_EVENT */
typedef struct {
    uint32_t type;
    uint32_t window;          /* the window it goes to, or 0 */
    double timestamp;         /* seconds since boot */
    double x, y;              /* in the window, points, y down from its top */
    double screen_x, screen_y;
    uint64_t modifiers;       /* CGEventFlags */
    uint32_t button;
    uint32_t click_count;
    double delta_x, delta_y;  /* scrolling, points; or mouse deltas */
    uint32_t key_code;        /* macOS virtual key code */
    uint32_t is_repeat;
    uint32_t length;          /* characters */
    uint16_t characters[8];
    uint16_t unmodified[8];
} FWSEvent;

/* FWS_WINDOW_MOVED (server -> client, when the server moves a window) */
typedef struct {
    FWSRect frame;
} FWSMoved;

/* FWS_ACTIVATED: the app became (1) or stopped being (0) the active one */
typedef struct {
    int32_t active;
} FWSActivated;

/* The viewer backend's stream (TCP): frames out, input in. */
#define FWS_VIEWER_PORT 5901
enum { FWS_VIEWER_FRAME = 1, FWS_VIEWER_INPUT = 2, FWS_VIEWER_HELLO = 3 };
typedef struct {
    uint32_t type;
    uint32_t length;  /* of what follows */
} FWSViewerHeader;
/* FWS_VIEWER_HELLO, server -> viewer */
typedef struct {
    uint32_t pixel_width, pixel_height;
    double scale;
} FWSViewerHello;
/* FWS_VIEWER_FRAME: a damaged rect in pixels, then its BGRA rows */
typedef struct {
    uint32_t x, y, width, height;
} FWSViewerFrame;
/* FWS_VIEWER_INPUT: an FWSEvent with screen coordinates in points (window and x, y unused) */

#endif
