/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * finch-windowserver: Finch's window server (docs/design/WINDOWSERVER.md).
 * It keeps the windows apps create, composites their shared buffers into
 * the screen with Skia, draws the cursor, and routes input to the right
 * app. Frames go to a backend: the host viewer over TCP (input comes back
 * the same way), or none (headless, for tests: FWS_SNAPSHOT).
 *
 *   finch-windowserver [--size WxH] [--scale S] [--socket PATH] [--viewer PORT | --headless]
 */
#include "FinchWSProtocol.h"
#include "include/core/SkCanvas.h"
#include "include/core/SkImage.h"
#include "include/core/SkBlurTypes.h"
#include "include/core/SkMaskFilter.h"
#include "include/core/SkPaint.h"
#include "include/core/SkPath.h"
#include "include/core/SkPathBuilder.h"
#include "include/core/SkPixmap.h"
#include "include/core/SkRRect.h"
#include <strings.h>
#include "include/core/SkSurface.h"
#include <algorithm>
#include <arpa/inet.h>
#include <errno.h>
#include <stdarg.h>
#include <fcntl.h>
#include <map>
#include <math.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <poll.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <string>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <time.h>
#include <unistd.h>
#include <vector>

static void
logf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));

static void
logf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    fprintf(stderr, "finch-windowserver: ");
    vfprintf(stderr, fmt, ap);
    fprintf(stderr, "\n");
    va_end(ap);
}

static double
now(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return ts.tv_sec + ts.tv_nsec / 1e9;
}

#pragma mark - Shared memory

namespace {
struct Shm {
    int fd = -1;
    void *ptr = nullptr;
    size_t length = 0;
};
}  // namespace

static Shm
shm_create(size_t length)
{
    Shm s;
    char name[64];
    static unsigned counter;
    snprintf(name, sizeof name, "/fws.%d.%u", getpid(), counter++);
    s.fd = shm_open(name, O_RDWR | O_CREAT | O_EXCL, 0600);
    if (s.fd < 0)
        return s;
    shm_unlink(name);
    if (ftruncate(s.fd, (off_t)length) < 0) {
        close(s.fd);
        s.fd = -1;
        return s;
    }
    s.ptr = mmap(nullptr, length, PROT_READ | PROT_WRITE, MAP_SHARED, s.fd, 0);
    if (s.ptr == MAP_FAILED) {
        close(s.fd);
        s.fd = -1;
        s.ptr = nullptr;
        return s;
    }
    memset(s.ptr, 0, length);
    s.length = length;
    return s;
}

static void
shm_free(Shm &s)
{
    if (s.ptr)
        munmap(s.ptr, s.length);
    if (s.fd >= 0)
        close(s.fd);
    s = Shm();
}

#pragma mark - State

namespace {
struct Client;

struct Window {
    uint32_t id;
    Client *owner;
    FWSRect frame;  /* points, global display coordinates */
    int32_t level = 0;
    uint32_t flags = 0;
    double alpha = 1;
    bool ordered = false;
    uint64_t order = 0;  /* higher is nearer the front within a level */
    std::string title;
    Shm buffer;
    uint32_t pw = 0, ph = 0, bpr = 0;
};

struct Client {
    int fd;
    int32_t pid = 0;
    std::string name;
    uint32_t id;
    std::vector<uint8_t> in;
};
}  // namespace

static uint32_t display_id = 1;
static double screen_w = 1280, screen_h = 800, scale = 2, refresh = 60;
static uint32_t pixel_w, pixel_h;
static std::map<uint32_t, Window *> windows;
static std::vector<Client *> clients;
static uint32_t next_window = 1, next_client = 1;
static uint64_t order_counter = 1;
static Shm screen;  /* the composited frame, BGRA premultiplied */
static sk_sp<SkSurface> surface;
static SkIRect damage = SkIRect::MakeEmpty();
static double cursor_x = 100, cursor_y = 100;
static bool cursor_visible = true;
static int32_t cursor_shape = FWS_CURSOR_ARROW;
static uint32_t capture_window, key_window;
static int32_t active_pid;
static uint64_t buttons_down;
static double last_click_time, last_click_x, last_click_y;
static uint32_t click_count;
static int viewer_listen = -1, viewer_fd = -1;

static void
damage_points(const FWSRect &r)
{
    SkRect pr = SkRect::MakeXYWH((float)(r.x * scale), (float)(r.y * scale), (float)(r.width * scale),
                                 (float)(r.height * scale));
    pr.outset(24 * (float)scale, 24 * (float)scale);  /* shadows */
    damage.join(pr.roundOut());
    damage.intersect(SkIRect::MakeWH((int)pixel_w, (int)pixel_h));
}

static void
damage_all(void)
{
    damage = SkIRect::MakeWH((int)pixel_w, (int)pixel_h);
}

static void
damage_cursor(void)
{
    damage_points({cursor_x - 4, cursor_y - 4, 32, 32});
}

/* Windows from the back to the front. */
static std::vector<Window *>
stacking(void)
{
    std::vector<Window *> out;
    for (auto &kv : windows)
        if (kv.second->ordered)
            out.push_back(kv.second);
    std::sort(out.begin(), out.end(), [](Window *a, Window *b) {
        return a->level != b->level ? a->level < b->level : a->order < b->order;
    });
    return out;
}

#pragma mark - Compositing

static void
draw_cursor(SkCanvas *c)
{
    if (!cursor_visible)
        return;
    c->save();
    c->scale((float)scale, (float)scale);
    c->translate((float)cursor_x, (float)cursor_y);
    SkPathBuilder b;
    if (cursor_shape == FWS_CURSOR_IBEAM) {
        b.moveTo(-3, -8).lineTo(3, -8).moveTo(0, -8).lineTo(0, 8).moveTo(-3, 8).lineTo(3, 8);
        SkPaint p;
        p.setAntiAlias(true);
        p.setStyle(SkPaint::kStroke_Style);
        p.setStrokeWidth(3);
        p.setColor(SK_ColorWHITE);
        c->drawPath(b.snapshot(), p);
        p.setStrokeWidth(1.2f);
        p.setColor(SK_ColorBLACK);
        c->drawPath(b.snapshot(), p);
    } else {
        /* the arrow */
        b.moveTo(0, 0).lineTo(0, 17).lineTo(4.2f, 13).lineTo(7, 19.5f).lineTo(9.5f, 18.5f).lineTo(6.8f, 12.2f)
            .lineTo(12, 12).close();
        SkPaint p;
        p.setAntiAlias(true);
        p.setColor(SK_ColorBLACK);
        c->drawPath(b.snapshot(), p);
        p.setStyle(SkPaint::kStroke_Style);
        p.setStrokeWidth(1.2f);
        p.setColor(SK_ColorWHITE);
        c->drawPath(b.snapshot(), p);
    }
    c->restore();
}

/*
 * Fieldwork (docs/design/FIELDWORK.md), unless FINCH_THEME is Classic: a chalk
 * desktop, and windows with 6-point top corners and 2-point bottom ones, a
 * structural outline, and a shallow shadow (about two millimetres above the desk).
 */
static bool
fieldwork(void)
{
    static int on = -1;
    if (on < 0) {
        const char *t = getenv("FINCH_THEME");
        on = !(t && !strcasecmp(t, "Classic"));
    }
    return on;
}

/* Night: FINCH_APPEARANCE=Night (the session sets it with AppleInterfaceStyle Dark). */
static bool
night(void)
{
    const char *a = getenv("FINCH_APPEARANCE");
    return a && !strcasecmp(a, "Night");
}

static SkRRect
window_shape(const SkRect &r, uint32_t flags)
{
    float s = (float)scale;
    float top = (flags & FWS_WINDOW_TITLED) ? 6 * s : 4 * s, bottom = (flags & FWS_WINDOW_TITLED) ? 2 * s : 4 * s;
    SkVector radii[4] = {{top, top}, {top, top}, {bottom, bottom}, {bottom, bottom}};
    SkRRect rr;
    rr.setRectRadii(r, radii);
    return rr;
}

static void
composite(void)
{
    if (damage.isEmpty())
        return;
    SkCanvas *c = surface->getCanvas();
    c->save();
    c->clipRect(SkRect::Make(damage));
    /* the desktop */
    SkPaint bg;
    bg.setColor(!fieldwork() ? SkColorSetRGB(0x2b, 0x3a, 0x4a)
                : night() ? SkColorSetRGB(0x18, 0x1d, 0x1c) : SkColorSetRGB(0xf0, 0xef, 0xe9));
    c->drawPaint(bg);
    for (Window *w : stacking()) {
        if (!w->buffer.ptr)
            continue;
        SkRect dst = SkRect::MakeXYWH((float)(w->frame.x * scale), (float)(w->frame.y * scale), (float)w->pw,
                                      (float)w->ph);
        if (!SkRect::Make(damage).intersects(dst.makeOutset(40, 40)))
            continue;
        bool shaped = fieldwork() && (w->flags & FWS_WINDOW_SHADOW);
        if (shaped) {
            /* a close contact shadow and a soft ambient one */
            SkRRect shape = window_shape(dst, w->flags);
            SkPaint ambient;
            ambient.setColor(SkColorSetARGB((U8CPU)(34 * w->alpha), 0x24, 0x29, 0x25));
            ambient.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, 8 * (float)scale));
            SkRRect a = shape;
            a.offset(0, 3 * (float)scale);
            c->drawRRect(a, ambient);
            SkPaint contact;
            contact.setColor(SkColorSetARGB((U8CPU)(46 * w->alpha), 0x24, 0x29, 0x25));
            contact.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, 1.5f * (float)scale));
            SkRRect k = shape;
            k.offset(0, 1 * (float)scale);
            c->drawRRect(k, contact);
        } else if (w->flags & FWS_WINDOW_SHADOW) {
            SkPaint sp;
            sp.setColor(SkColorSetARGB((U8CPU)(90 * w->alpha), 0, 0, 0));
            sp.setMaskFilter(SkMaskFilter::MakeBlur(kNormal_SkBlurStyle, 9 * (float)scale));
            c->drawRRect(SkRRect::MakeRectXY(dst.makeOffset(0, 6 * (float)scale), 10 * (float)scale, 10 * (float)scale), sp);
        }
        SkImageInfo info = SkImageInfo::Make((int)w->pw, (int)w->ph, kBGRA_8888_SkColorType,
                                             (w->flags & FWS_WINDOW_OPAQUE) ? kOpaque_SkAlphaType : kPremul_SkAlphaType);
        sk_sp<SkImage> img = SkImages::RasterFromPixmap(SkPixmap(info, w->buffer.ptr, w->bpr), nullptr, nullptr);
        SkPaint wp;
        wp.setAlphaf((float)w->alpha);
        if (shaped) {
            SkRRect shape = window_shape(dst, w->flags);
            c->save();
            c->clipRRect(shape, true);
            c->drawImage(img, dst.x(), dst.y(), SkSamplingOptions(), &wp);
            c->restore();
            /* the structural outline: one device pixel, just inside the edge */
            SkPaint outline;
            outline.setAntiAlias(true);
            outline.setStyle(SkPaint::kStroke_Style);
            outline.setStrokeWidth(1);
            outline.setColor(night() ? SkColorSetARGB((U8CPU)(0xa0 * w->alpha), 0, 0, 0)
                                     : SkColorSetARGB((U8CPU)(0x40 * w->alpha), 0x24, 0x29, 0x25));
            SkRRect in = shape;
            in.inset(0.5f, 0.5f);
            c->drawRRect(in, outline);
        } else {
            c->drawImage(img, dst.x(), dst.y(), SkSamplingOptions(), &wp);
        }
    }
    draw_cursor(c);
    c->restore();
    /* to the viewer */
    if (viewer_fd >= 0) {
        FWSViewerHeader h = {FWS_VIEWER_FRAME, (uint32_t)(sizeof(FWSViewerFrame) + 4 * damage.width() * damage.height())};
        FWSViewerFrame f = {(uint32_t)damage.x(), (uint32_t)damage.y(), (uint32_t)damage.width(), (uint32_t)damage.height()};
        std::vector<uint8_t> out(sizeof h + h.length);
        memcpy(out.data(), &h, sizeof h);
        memcpy(out.data() + sizeof h, &f, sizeof f);
        uint8_t *rows = out.data() + sizeof h + sizeof f;
        size_t stride = (size_t)pixel_w * 4;
        for (int y = 0; y < damage.height(); y++)
            memcpy(rows + (size_t)y * damage.width() * 4,
                   (uint8_t *)screen.ptr + (size_t)(damage.y() + y) * stride + (size_t)damage.x() * 4,
                   (size_t)damage.width() * 4);
        size_t sent = 0;
        while (sent < out.size()) {
            ssize_t n = write(viewer_fd, out.data() + sent, out.size() - sent);
            if (n <= 0) {
                if (n < 0 && errno == EINTR)
                    continue;
                logf("viewer gone");
                close(viewer_fd);
                viewer_fd = -1;
                break;
            }
            sent += (size_t)n;
        }
    }
    damage = SkIRect::MakeEmpty();
}

#pragma mark - Sending

static bool
send_all(int fd, const void *buf, size_t len, int pass_fd = -1)
{
    struct msghdr msg = {};
    struct iovec iov = {(void *)buf, len};
    msg.msg_iov = &iov;
    msg.msg_iovlen = 1;
    char control[CMSG_SPACE(sizeof(int))];
    if (pass_fd >= 0) {
        memset(control, 0, sizeof control);
        msg.msg_control = control;
        msg.msg_controllen = sizeof control;
        struct cmsghdr *cm = CMSG_FIRSTHDR(&msg);
        cm->cmsg_level = SOL_SOCKET;
        cm->cmsg_type = SCM_RIGHTS;
        cm->cmsg_len = CMSG_LEN(sizeof(int));
        memcpy(CMSG_DATA(cm), &pass_fd, sizeof(int));
    }
    size_t done = 0;
    while (done < len) {
        ssize_t n = sendmsg(fd, &msg, 0);
        if (n < 0 && errno == EINTR)
            continue;
        if (n <= 0)
            return false;
        done += (size_t)n;
        iov.iov_base = (char *)buf + done;
        iov.iov_len = len - done;
        msg.msg_control = nullptr;
        msg.msg_controllen = 0;
    }
    return true;
}

static void
send_message(Client *c, uint32_t type, uint32_t serial, uint32_t window, const void *body, size_t size, int pass_fd = -1)
{
    std::vector<uint8_t> buf(sizeof(FWSHeader) + size);
    FWSHeader h = {type, (uint32_t)size, serial, window};
    memcpy(buf.data(), &h, sizeof h);
    if (size)
        memcpy(buf.data() + sizeof h, body, size);
    send_all(c->fd, buf.data(), buf.size(), pass_fd);
}

static void
send_buffer(Client *c, uint32_t serial, Window *w)
{
    FWSBuffer b = {w->id, w->pw, w->ph, w->bpr, w->buffer.length};
    send_message(c, FWS_REPLY, serial, w->id, &b, sizeof b, w->buffer.fd);
}

static FWSDisplayInfo
display_info(Client *c)
{
    FWSDisplayInfo d = {c ? c->id : 0, display_id, screen_w, screen_h, scale, refresh};
    return d;
}

#pragma mark - Windows

static bool
allocate_buffer(Window *w)
{
    uint32_t pw = (uint32_t)std::max(1.0, ceil(w->frame.width * scale));
    uint32_t ph = (uint32_t)std::max(1.0, ceil(w->frame.height * scale));
    uint32_t bpr = (pw * 4 + 63) & ~63u;
    Shm s = shm_create((size_t)bpr * ph);
    if (!s.ptr)
        return false;
    shm_free(w->buffer);
    w->buffer = s;
    w->pw = pw, w->ph = ph, w->bpr = bpr;
    return true;
}

static void
destroy_window(Window *w)
{
    if (w->ordered)
        damage_points(w->frame);
    if (capture_window == w->id)
        capture_window = 0;
    if (key_window == w->id)
        key_window = 0;
    shm_free(w->buffer);
    windows.erase(w->id);
    delete w;
}

static Window *
find_window(Client *c, uint32_t id)
{
    auto it = windows.find(id);
    return it != windows.end() && it->second->owner == c ? it->second : nullptr;
}

static void
set_active(int32_t pid)
{
    if (pid == active_pid)
        return;
    for (Client *c : clients) {
        if (c->pid == active_pid || c->pid == pid) {
            FWSActivated a = {c->pid == pid};
            send_message(c, FWS_ACTIVATED, 0, 0, &a, sizeof a);
        }
    }
    active_pid = pid;
}

#pragma mark - Input

static Window *
window_at(double x, double y)
{
    std::vector<Window *> s = stacking();
    for (auto it = s.rbegin(); it != s.rend(); ++it) {
        Window *w = *it;
        if (w->flags & FWS_WINDOW_IGNORES_MOUSE)
            continue;
        if (x >= w->frame.x && x < w->frame.x + w->frame.width && y >= w->frame.y && y < w->frame.y + w->frame.height)
            return w;
    }
    return nullptr;
}

static void
deliver(Window *w, FWSEvent e)
{
    if (!w)
        return;
    e.window = w->id;
    e.x = e.screen_x - w->frame.x;
    e.y = e.screen_y - w->frame.y;
    send_message(w->owner, FWS_EVENT, 0, w->id, &e, sizeof e);
}

static void
handle_input(FWSEvent e)
{
    e.timestamp = now();
    bool mouse = e.type == FWS_EVENT_MOUSE_MOVED || e.type == FWS_EVENT_LEFT_DRAGGED ||
                 e.type == FWS_EVENT_RIGHT_DRAGGED || e.type == FWS_EVENT_OTHER_DRAGGED ||
                 e.type == FWS_EVENT_LEFT_DOWN || e.type == FWS_EVENT_LEFT_UP || e.type == FWS_EVENT_RIGHT_DOWN ||
                 e.type == FWS_EVENT_RIGHT_UP || e.type == FWS_EVENT_OTHER_DOWN || e.type == FWS_EVENT_OTHER_UP ||
                 e.type == FWS_EVENT_SCROLL;
    if (mouse) {
        damage_cursor();
        cursor_x = std::min(screen_w - 1, std::max(0.0, e.screen_x));
        cursor_y = std::min(screen_h - 1, std::max(0.0, e.screen_y));
        e.screen_x = cursor_x, e.screen_y = cursor_y;
        damage_cursor();
    }
    bool down = e.type == FWS_EVENT_LEFT_DOWN || e.type == FWS_EVENT_RIGHT_DOWN || e.type == FWS_EVENT_OTHER_DOWN;
    bool up = e.type == FWS_EVENT_LEFT_UP || e.type == FWS_EVENT_RIGHT_UP || e.type == FWS_EVENT_OTHER_UP;
    if (down) {
        double t = e.timestamp;
        if (t - last_click_time < 0.5 && fabs(e.screen_x - last_click_x) < 4 && fabs(e.screen_y - last_click_y) < 4)
            click_count++;
        else
            click_count = 1;
        last_click_time = t, last_click_x = e.screen_x, last_click_y = e.screen_y;
        e.click_count = click_count;
        Window *w = window_at(e.screen_x, e.screen_y);
        capture_window = w ? w->id : 0;
        buttons_down |= 1ull << e.button;
        if (w)
            set_active(w->owner->pid);
        deliver(w, e);
        return;
    }
    if (up) {
        e.click_count = click_count;
        Window *w = capture_window && windows.count(capture_window) ? windows[capture_window] : window_at(e.screen_x, e.screen_y);
        buttons_down &= ~(1ull << e.button);
        if (!buttons_down)
            capture_window = 0;
        deliver(w, e);
        return;
    }
    if (mouse) {
        Window *w = capture_window && windows.count(capture_window) ? windows[capture_window] : window_at(e.screen_x, e.screen_y);
        deliver(w, e);
        return;
    }
    /* keys: to the key window */
    if (key_window && windows.count(key_window))
        deliver(windows[key_window], e);
}

#pragma mark - Requests

static void
handle(Client *c, const FWSHeader &h, const uint8_t *body)
{
    auto want = [&](size_t n) { return h.size >= n; };
    switch (h.type) {
    case FWS_HELLO: {
        if (!want(sizeof(FWSHello)))
            return;
        const FWSHello *m = (const FWSHello *)body;
        c->pid = m->pid;
        c->name.assign(m->name, strnlen(m->name, sizeof m->name));
        FWSDisplayInfo d = display_info(c);
        send_message(c, FWS_REPLY, h.serial, 0, &d, sizeof d);
        if (!active_pid)
            set_active(c->pid);
        break;
    }
    case FWS_CREATE_WINDOW: {
        if (!want(sizeof(FWSWindowSpec)))
            return;
        const FWSWindowSpec *m = (const FWSWindowSpec *)body;
        Window *w = new Window();
        w->id = next_window++;
        w->owner = c;
        w->frame = m->frame;
        w->level = m->level;
        w->flags = m->flags;
        if (!allocate_buffer(w)) {
            delete w;
            FWSBuffer none = {};
            send_message(c, FWS_REPLY, h.serial, 0, &none, sizeof none);
            return;
        }
        windows[w->id] = w;
        send_buffer(c, h.serial, w);
        break;
    }
    case FWS_DESTROY_WINDOW:
        if (Window *w = find_window(c, h.window))
            destroy_window(w);
        break;
    case FWS_SET_FRAME: {
        Window *w = find_window(c, h.window);
        if (!w || !want(sizeof(FWSWindowSpec)))
            return;
        const FWSWindowSpec *m = (const FWSWindowSpec *)body;
        if (w->ordered)
            damage_points(w->frame);
        bool resized = m->frame.width != w->frame.width || m->frame.height != w->frame.height;
        w->frame = m->frame;
        if (w->ordered)
            damage_points(w->frame);
        if (resized) {
            allocate_buffer(w);
            send_buffer(c, h.serial, w);
        } else if (h.serial) {
            FWSBuffer b = {w->id, w->pw, w->ph, w->bpr, 0};
            send_message(c, FWS_REPLY, h.serial, w->id, &b, sizeof b);
        }
        break;
    }
    case FWS_ORDER: {
        Window *w = find_window(c, h.window);
        if (!w || !want(sizeof(FWSOrder)))
            return;
        const FWSOrder *m = (const FWSOrder *)body;
        if (m->mode == FWS_ORDER_OUT) {
            w->ordered = false;
        } else {
            w->ordered = true;
            auto rel = windows.find(m->relative_to);
            if (m->relative_to && rel != windows.end()) {
                /* just above or below the other window: renumber around it */
                uint64_t base = rel->second->order;
                for (auto &kv : windows)
                    if (kv.second != w && kv.second->order > base)
                        kv.second->order += 2;
                w->order = m->mode == FWS_ORDER_ABOVE ? base + 1 : base;
                if (m->mode == FWS_ORDER_BELOW)
                    rel->second->order = base + 1;
            } else {
                w->order = m->mode == FWS_ORDER_ABOVE ? (order_counter += 2) : 0;
            }
        }
        damage_points(w->frame);
        break;
    }
    case FWS_SET_LEVEL:
        if (Window *w = find_window(c, h.window); w && want(sizeof(FWSInt))) {
            w->level = ((const FWSInt *)body)->value;
            damage_points(w->frame);
        }
        break;
    case FWS_SET_ALPHA:
        if (Window *w = find_window(c, h.window); w && want(sizeof(FWSDouble))) {
            w->alpha = std::min(1.0, std::max(0.0, ((const FWSDouble *)body)->alpha));
            damage_points(w->frame);
        }
        break;
    case FWS_SET_FLAGS:
        if (Window *w = find_window(c, h.window); w && want(sizeof(FWSInt))) {
            w->flags = (uint32_t)((const FWSInt *)body)->value;
            damage_points(w->frame);
        }
        break;
    case FWS_SET_TITLE:
        if (Window *w = find_window(c, h.window))
            w->title.assign((const char *)body, h.size);
        break;
    case FWS_FLUSH:
        if (Window *w = find_window(c, h.window); w && w->ordered) {
            FWSRect r = w->frame;
            if (want(sizeof(FWSFlush))) {
                const FWSRect &d = ((const FWSFlush *)body)->rect;
                if (d.width > 0 && d.height > 0)
                    r = {w->frame.x + d.x, w->frame.y + d.y, d.width, d.height};
            }
            damage_points(r);
        }
        break;
    case FWS_SET_CURSOR:
        if (want(sizeof(FWSCursor))) {
            cursor_shape = ((const FWSCursor *)body)->shape;
            damage_cursor();
        }
        break;
    case FWS_WARP_CURSOR:
        if (want(sizeof(FWSPoint))) {
            damage_cursor();
            cursor_x = ((const FWSPoint *)body)->x;
            cursor_y = ((const FWSPoint *)body)->y;
            damage_cursor();
        }
        break;
    case FWS_SET_CURSOR_VISIBLE:
        if (want(sizeof(FWSInt))) {
            cursor_visible = ((const FWSInt *)body)->value != 0;
            damage_cursor();
        }
        break;
    case FWS_MAKE_KEY:
        if (Window *w = find_window(c, h.window)) {
            key_window = w->id;
            set_active(c->pid);
        }
        break;
    case FWS_WINDOW_LIST: {
        std::vector<Window *> s = stacking();
        std::vector<FWSWindowInfo> list;
        for (auto it = s.rbegin(); it != s.rend(); ++it) {
            Window *w = *it;
            FWSWindowInfo i = {};
            i.window = w->id, i.pid = w->owner->pid, i.level = w->level, i.flags = w->flags, i.on_screen = 1;
            i.alpha = w->alpha, i.frame = w->frame;
            snprintf(i.owner, sizeof i.owner, "%s", w->owner->name.c_str());
            snprintf(i.title, sizeof i.title, "%s", w->title.c_str());
            list.push_back(i);
        }
        for (auto &kv : windows)
            if (!kv.second->ordered) {
                Window *w = kv.second;
                FWSWindowInfo i = {};
                i.window = w->id, i.pid = w->owner->pid, i.level = w->level, i.flags = w->flags, i.on_screen = 0;
                i.alpha = w->alpha, i.frame = w->frame;
                snprintf(i.owner, sizeof i.owner, "%s", w->owner->name.c_str());
                snprintf(i.title, sizeof i.title, "%s", w->title.c_str());
                list.push_back(i);
            }
        std::vector<uint8_t> out(4 + list.size() * sizeof(FWSWindowInfo));
        uint32_t n = (uint32_t)list.size();
        memcpy(out.data(), &n, 4);
        if (n)
            memcpy(out.data() + 4, list.data(), list.size() * sizeof(FWSWindowInfo));
        send_message(c, FWS_REPLY, h.serial, 0, out.data(), out.size());
        break;
    }
    case FWS_POST_EVENT:
        if (want(sizeof(FWSEvent)))
            handle_input(*(const FWSEvent *)body);
        break;
    case FWS_SNAPSHOT: {
        composite();
        size_t len = (size_t)pixel_w * pixel_h * 4;
        Shm copy = shm_create(len);
        if (copy.ptr)
            memcpy(copy.ptr, screen.ptr, len);
        FWSBuffer b = {0, pixel_w, pixel_h, pixel_w * 4, copy.ptr ? len : 0};
        send_message(c, FWS_REPLY, h.serial, 0, &b, sizeof b, copy.fd);
        shm_free(copy);
        break;
    }
    default:
        logf("unknown request %u from %s", h.type, c->name.c_str());
        break;
    }
}

static void
drop_client(Client *c)
{
    std::vector<Window *> mine;
    for (auto &kv : windows)
        if (kv.second->owner == c)
            mine.push_back(kv.second);
    for (Window *w : mine)
        destroy_window(w);
    close(c->fd);
    clients.erase(std::find(clients.begin(), clients.end(), c));
    if (active_pid == c->pid)
        active_pid = 0;
    delete c;
}

/* Read what's there; handle every complete message. False when the client is gone. */
static bool
read_client(Client *c)
{
    uint8_t buf[65536];
    ssize_t n = read(c->fd, buf, sizeof buf);
    if (n <= 0)
        return n < 0 && (errno == EINTR || errno == EAGAIN);
    c->in.insert(c->in.end(), buf, buf + n);
    size_t off = 0;
    while (c->in.size() - off >= sizeof(FWSHeader)) {
        FWSHeader h;
        memcpy(&h, c->in.data() + off, sizeof h);
        if (h.size > (64u << 20))
            return false;
        if (c->in.size() - off < sizeof h + h.size)
            break;
        handle(c, h, c->in.data() + off + sizeof h);
        off += sizeof h + h.size;
    }
    c->in.erase(c->in.begin(), c->in.begin() + (long)off);
    return true;
}

#pragma mark - The viewer backend

static std::vector<uint8_t> viewer_in;

static void
viewer_connected(int fd)
{
    if (viewer_fd >= 0)
        close(viewer_fd);
    viewer_fd = fd;
    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
    FWSViewerHeader h = {FWS_VIEWER_HELLO, sizeof(FWSViewerHello)};
    FWSViewerHello hello = {pixel_w, pixel_h, scale};
    send_all(fd, &h, sizeof h);
    send_all(fd, &hello, sizeof hello);
    viewer_in.clear();
    damage_all();
    logf("viewer connected");
}

static void
read_viewer(void)
{
    uint8_t buf[4096];
    ssize_t n = read(viewer_fd, buf, sizeof buf);
    if (n <= 0) {
        if (n < 0 && (errno == EINTR || errno == EAGAIN))
            return;
        close(viewer_fd);
        viewer_fd = -1;
        logf("viewer disconnected");
        return;
    }
    viewer_in.insert(viewer_in.end(), buf, buf + n);
    size_t off = 0;
    while (viewer_in.size() - off >= sizeof(FWSViewerHeader)) {
        FWSViewerHeader h;
        memcpy(&h, viewer_in.data() + off, sizeof h);
        if (viewer_in.size() - off < sizeof h + h.length)
            break;
        if (h.type == FWS_VIEWER_INPUT && h.length >= sizeof(FWSEvent)) {
            FWSEvent e;
            memcpy(&e, viewer_in.data() + off + sizeof h, sizeof e);
            handle_input(e);
        }
        off += sizeof h + h.length;
    }
    viewer_in.erase(viewer_in.begin(), viewer_in.begin() + (long)off);
}

#pragma mark - main

int
main(int argc, char **argv)
{
    const char *socket_path = getenv(FWS_SOCKET_ENV) ? getenv(FWS_SOCKET_ENV) : FWS_SOCKET_DEFAULT;
    int viewer_port = FWS_VIEWER_PORT;
    for (int i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--size") && i + 1 < argc)
            sscanf(argv[++i], "%lfx%lf", &screen_w, &screen_h);
        else if (!strcmp(argv[i], "--scale") && i + 1 < argc)
            scale = atof(argv[++i]);
        else if (!strcmp(argv[i], "--socket") && i + 1 < argc)
            socket_path = argv[++i];
        else if (!strcmp(argv[i], "--viewer") && i + 1 < argc)
            viewer_port = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--headless"))
            viewer_port = 0;
        else {
            fprintf(stderr, "usage: %s [--size WxH] [--scale S] [--socket PATH] [--viewer PORT | --headless]\n", argv[0]);
            return 2;
        }
    }
    signal(SIGPIPE, SIG_IGN);
    pixel_w = (uint32_t)ceil(screen_w * scale), pixel_h = (uint32_t)ceil(screen_h * scale);
    screen = shm_create((size_t)pixel_w * pixel_h * 4);
    if (!screen.ptr) {
        logf("can't allocate the screen");
        return 1;
    }
    SkImageInfo info = SkImageInfo::Make((int)pixel_w, (int)pixel_h, kBGRA_8888_SkColorType, kPremul_SkAlphaType);
    surface = SkSurfaces::WrapPixels(info, screen.ptr, (size_t)pixel_w * 4);
    damage_all();
    composite();

    int listen_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    struct sockaddr_un addr = {};
    addr.sun_family = AF_UNIX;
    if (strlen(socket_path) >= sizeof addr.sun_path) {
        logf("socket path too long (at most %zu bytes): %s", sizeof addr.sun_path - 1, socket_path);
        return 1;
    }
    snprintf(addr.sun_path, sizeof addr.sun_path, "%s", socket_path);
    unlink(socket_path);
    if (bind(listen_fd, (struct sockaddr *)&addr, sizeof addr) < 0 || listen(listen_fd, 16) < 0) {
        logf("can't listen on %s: %s", socket_path, strerror(errno));
        return 1;
    }
    if (viewer_port) {
        viewer_listen = socket(AF_INET, SOCK_STREAM, 0);
        int one = 1;
        setsockopt(viewer_listen, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        struct sockaddr_in in = {};
        in.sin_family = AF_INET;
        in.sin_port = htons((uint16_t)viewer_port);
        in.sin_addr.s_addr = htonl(INADDR_ANY);
        if (bind(viewer_listen, (struct sockaddr *)&in, sizeof in) < 0 || listen(viewer_listen, 1) < 0) {
            logf("can't listen for the viewer on port %d: %s", viewer_port, strerror(errno));
            return 1;
        }
    }
    logf("%gx%g points at %gx on %s%s", screen_w, screen_h, scale, socket_path,
         viewer_port ? ", viewer port open" : " (headless)");

    double frame_interval = 1.0 / refresh, last = 0;
    for (;;) {
        std::vector<struct pollfd> fds;
        fds.push_back({listen_fd, POLLIN, 0});
        if (viewer_listen >= 0)
            fds.push_back({viewer_listen, POLLIN, 0});
        if (viewer_fd >= 0)
            fds.push_back({viewer_fd, POLLIN, 0});
        size_t first_client = fds.size();
        for (Client *c : clients)
            fds.push_back({c->fd, POLLIN, 0});
        int timeout = damage.isEmpty() ? -1 : std::max(0, (int)((last + frame_interval - now()) * 1000));
        int n = poll(fds.data(), (nfds_t)fds.size(), timeout);
        if (n < 0 && errno != EINTR)
            break;
        for (size_t i = 0; i < fds.size(); i++) {
            if (!(fds[i].revents & (POLLIN | POLLHUP | POLLERR)))
                continue;
            if (fds[i].fd == listen_fd) {
                int fd = accept(listen_fd, nullptr, nullptr);
                if (fd >= 0) {
                    Client *c = new Client();
                    c->fd = fd;
                    c->id = next_client++;
                    clients.push_back(c);
                }
            } else if (fds[i].fd == viewer_listen) {
                int fd = accept(viewer_listen, nullptr, nullptr);
                if (fd >= 0)
                    viewer_connected(fd);
            } else if (fds[i].fd == viewer_fd) {
                read_viewer();
            } else if (i >= first_client) {
                Client *c = nullptr;
                for (Client *k : clients)
                    if (k->fd == fds[i].fd)
                        c = k;
                if (c && !read_client(c))
                    drop_client(c);
            }
        }
        if (!damage.isEmpty() && now() - last >= frame_interval) {
            composite();
            last = now();
        }
    }
    return 0;
}
