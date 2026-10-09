/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * CGContextDrawPDFPage: a PDF content-stream interpreter (ISO 32000-1
 * sections 8 and 9) that draws through the CGContext API, so a page lands
 * on any context: bitmap, PDF, layer. The page's content is drawn in the
 * context's current user space, which is the page's default space (no
 * clip to its boxes, as Apple's).
 *
 * Covered: paths, clipping, the graphics state and ExtGState (with soft
 * masks), every colour space (device, CIE-based, ICC, indexed, separation
 * and DeviceN through their tint transforms, patterns), functions (all four
 * types), images (with masks, soft masks and colour-key masking; Flate,
 * LZW, run-length, ASCII and DCT data), inline images, shadings (axial and
 * radial through CGShading; function-based and mesh shadings by
 * subdivision), tiling and shading patterns, form XObjects and
 * transparency groups, and text in embedded TrueType, CFF and Type 1 fonts
 * (through FreeType), Type 3 fonts, and substitutes for fonts that aren't
 * embedded.
 */
#include "CGContextInternal.h"
#include "CGFontInternal.h"
#include "CGPDFInternal.h"
#include "include/core/SkFont.h"
#include <ft2build.h>
#include FT_FREETYPE_H
#include FT_TRUETYPE_TABLES_H
#include <algorithm>
#include <math.h>
#include <memory>
#include <pthread.h>
#include <string.h>

namespace {

typedef std::vector<double> Vec;

/* Numbers from an array, or nothing. */
static bool
numbers(CGPDFArrayRef a, Vec &out)
{
    out.clear();
    if (!a)
        return false;
    for (size_t i = 0; i < CGPDFArrayGetCount(a); i++) {
        CGPDFReal v = 0;
        if (!CGPDFArrayGetNumber(a, i, &v))
            return false;
        out.push_back(v);
    }
    return true;
}

static bool
dict_numbers(CGPDFDictionaryRef d, const char *key, Vec &out)
{
    CGPDFArrayRef a;
    return d && CGPDFDictionaryGetArray(d, key, &a) && numbers(a, out);
}

static double
dict_number(CGPDFDictionaryRef d, const char *key, double fallback)
{
    CGPDFReal v;
    return d && CGPDFDictionaryGetNumber(d, key, &v) ? v : fallback;
}

static CGPDFDictionaryRef
object_dict(CGPDFObjectRef o)
{
    CGPDFDictionaryRef d = NULL;
    CGPDFStreamRef s;
    if (CGPDFObjectGetValue(o, kCGPDFObjectTypeDictionary, &d))
        return d;
    if (CGPDFObjectGetValue(o, kCGPDFObjectTypeStream, &s))
        return CGPDFStreamGetDictionary(s);
    return NULL;
}

static std::vector<uint8_t>
stream_bytes(CGPDFStreamRef s, CGPDFDataFormat *format = NULL)
{
    std::vector<uint8_t> out;
    CFDataRef d = CGPDFStreamDecode(s, format, true);
    if (d) {
        out.assign(CFDataGetBytePtr(d), CFDataGetBytePtr(d) + CFDataGetLength(d));
        CFRelease(d);
    }
    return out;
}

static CGAffineTransform
matrix_of(CGPDFDictionaryRef d, const char *key)
{
    Vec m;
    if (dict_numbers(d, key, m) && m.size() == 6)
        return CGAffineTransformMake(m[0], m[1], m[2], m[3], m[4], m[5]);
    return CGAffineTransformIdentity;
}

#pragma mark - Functions (section 7.10)

struct Function {
    int type = -1;
    Vec domain, range;
    /* type 0 */
    std::vector<int> size;
    int bps = 8;
    Vec encode, decode, samples;
    /* type 2 */
    Vec c0, c1;
    double N = 1;
    /* type 3 */
    std::vector<std::unique_ptr<Function>> parts;
    Vec bounds;
    /* type 4 */
    std::vector<std::string> code;
    int outputs() const { return (int)(range.size() / 2 ? range.size() / 2 : c0.size() ? c0.size() : parts.size() ? parts[0]->outputs() : 1); }
    void eval(const double *in, double *out) const;
};

static std::unique_ptr<Function> parse_function(CGPDFObjectRef o, int depth = 0);

/* PostScript calculator functions, tokenized; braces nest procedures for if/ifelse. */
static void
tokenize_ps(const std::vector<uint8_t> &src, std::vector<std::string> &out)
{
    for (size_t i = 0; i < src.size();) {
        uint8_t c = src[i];
        if (CGPDFIsSpace(c)) {
            i++;
        } else if (c == '{' || c == '}') {
            out.push_back(std::string(1, (char)c));
            i++;
        } else if (c == '%') {
            while (i < src.size() && src[i] != '\n' && src[i] != '\r')
                i++;
        } else {
            size_t j = i;
            while (j < src.size() && !CGPDFIsSpace(src[j]) && src[j] != '{' && src[j] != '}')
                j++;
            out.push_back(std::string((const char *)&src[i], j - i));
            i = j;
        }
    }
}

static size_t
run_ps(const std::vector<std::string> &code, size_t pc, std::vector<double> &st, int depth)
{
    auto pop = [&]() {
        if (st.empty())
            return 0.0;
        double v = st.back();
        st.pop_back();
        return v;
    };
    while (pc < code.size()) {
        const std::string &t = code[pc++];
        if (t == "}")
            return pc;
        if (t == "{") {
            /* a procedure: find its end, and an optional second one */
            size_t start = pc, d = 1;
            while (pc < code.size() && d) {
                if (code[pc] == "{")
                    d++;
                else if (code[pc] == "}")
                    d--;
                pc++;
            }
            size_t end1 = pc, start2 = 0, end2 = 0;
            if (pc < code.size() && code[pc] == "{") {
                start2 = ++pc, d = 1;
                while (pc < code.size() && d) {
                    if (code[pc] == "{")
                        d++;
                    else if (code[pc] == "}")
                        d--;
                    pc++;
                }
                end2 = pc;
            }
            (void)end1, (void)end2;
            if (pc < code.size() && depth < 32) {
                const std::string &op = code[pc++];
                if (op == "if") {
                    if (pop() != 0)
                        run_ps(code, start, st, depth + 1);
                } else if (op == "ifelse") {
                    bool cond = pop() != 0;
                    run_ps(code, cond ? start : start2, st, depth + 1);
                }
            }
            continue;
        }
        char *e;
        double v = strtod(t.c_str(), &e);
        if (e != t.c_str() && *e == 0) {
            st.push_back(v);
            continue;
        }
        if (st.size() > 1000)
            return code.size();
        double a, b;
        if (t == "add") b = pop(), a = pop(), st.push_back(a + b);
        else if (t == "sub") b = pop(), a = pop(), st.push_back(a - b);
        else if (t == "mul") b = pop(), a = pop(), st.push_back(a * b);
        else if (t == "div") b = pop(), a = pop(), st.push_back(b ? a / b : 0);
        else if (t == "idiv") b = pop(), a = pop(), st.push_back((long)b ? (double)((long)a / (long)b) : 0);
        else if (t == "mod") b = pop(), a = pop(), st.push_back((long)b ? (double)((long)a % (long)b) : 0);
        else if (t == "neg") st.push_back(-pop());
        else if (t == "abs") st.push_back(fabs(pop()));
        else if (t == "ceiling") st.push_back(ceil(pop()));
        else if (t == "floor") st.push_back(floor(pop()));
        else if (t == "round") st.push_back(floor(pop() + 0.5));
        else if (t == "truncate") st.push_back(trunc(pop()));
        else if (t == "cvi") st.push_back(trunc(pop()));
        else if (t == "cvr") ;
        else if (t == "sqrt") st.push_back(sqrt(fmax(0, pop())));
        else if (t == "sin") st.push_back(sin(pop() * M_PI / 180));
        else if (t == "cos") st.push_back(cos(pop() * M_PI / 180));
        else if (t == "atan") {
            b = pop(), a = pop();
            double r = atan2(a, b) * 180 / M_PI;
            st.push_back(r < 0 ? r + 360 : r);
        } else if (t == "exp") b = pop(), a = pop(), st.push_back(pow(a, b));
        else if (t == "ln") st.push_back(log(pop()));
        else if (t == "log") st.push_back(log10(pop()));
        else if (t == "eq") b = pop(), a = pop(), st.push_back(a == b);
        else if (t == "ne") b = pop(), a = pop(), st.push_back(a != b);
        else if (t == "gt") b = pop(), a = pop(), st.push_back(a > b);
        else if (t == "ge") b = pop(), a = pop(), st.push_back(a >= b);
        else if (t == "lt") b = pop(), a = pop(), st.push_back(a < b);
        else if (t == "le") b = pop(), a = pop(), st.push_back(a <= b);
        else if (t == "and") b = pop(), a = pop(), st.push_back((double)((long)a & (long)b));
        else if (t == "or") b = pop(), a = pop(), st.push_back((double)((long)a | (long)b));
        else if (t == "xor") b = pop(), a = pop(), st.push_back((double)((long)a ^ (long)b));
        else if (t == "not") a = pop(), st.push_back(a == 0 || a == 1 ? (double)(a == 0) : (double)~(long)a);
        else if (t == "bitshift") {
            b = pop(), a = pop();
            long s = (long)b, v2 = (long)a;
            st.push_back((double)(s >= 0 ? v2 << s : v2 >> -s));
        } else if (t == "true") st.push_back(1);
        else if (t == "false") st.push_back(0);
        else if (t == "pop") pop();
        else if (t == "dup") { a = pop(); st.push_back(a); st.push_back(a); }
        else if (t == "exch") { b = pop(), a = pop(); st.push_back(b); st.push_back(a); }
        else if (t == "copy") {
            long n = (long)pop();
            if (n > 0 && (size_t)n <= st.size())
                st.insert(st.end(), st.end() - n, st.end());
        } else if (t == "index") {
            long n = (long)pop();
            if (n >= 0 && (size_t)n < st.size())
                st.push_back(st[st.size() - 1 - (size_t)n]);
        } else if (t == "roll") {
            long j = (long)pop(), n = (long)pop();
            if (n > 0 && (size_t)n <= st.size()) {
                j = ((j % n) + n) % n;
                std::rotate(st.end() - n, st.end() - j, st.end());
            }
        }
    }
    return pc;
}

void
Function::eval(const double *in, double *out) const
{
    int m = (int)domain.size() / 2, n = outputs();
    double x[16];
    for (int i = 0; i < m && i < 16; i++)
        x[i] = fmin(domain[2 * i + 1], fmax(domain[2 * i], in[i]));
    switch (type) {
    case 0: {
        /* sampled: multilinear interpolation between the samples around the input */
        int dims = std::min(m, 8);
        double e[8];
        int lo[8];
        double frac[8];
        for (int i = 0; i < dims; i++) {
            double e0 = encode.size() > (size_t)2 * i + 1 ? encode[2 * i] : 0;
            double e1 = encode.size() > (size_t)2 * i + 1 ? encode[2 * i + 1] : size[i] - 1;
            double d0 = domain[2 * i], d1 = domain[2 * i + 1];
            e[i] = d1 != d0 ? e0 + (x[i] - d0) * (e1 - e0) / (d1 - d0) : e0;
            e[i] = fmin(size[i] - 1, fmax(0, e[i]));
            lo[i] = std::min((int)floor(e[i]), std::max(0, size[i] - 2));
            frac[i] = e[i] - lo[i];
            if (size[i] == 1)
                lo[i] = 0, frac[i] = 0;
        }
        for (int k = 0; k < n; k++) {
            double acc = 0;
            for (int corner = 0; corner < (1 << dims); corner++) {
                double w = 1;
                size_t index = 0, stride = 1;
                for (int i = 0; i < dims; i++) {
                    int bit = (corner >> i) & 1;
                    w *= bit ? frac[i] : 1 - frac[i];
                    int idx = std::min(lo[i] + bit, size[i] - 1);
                    index += (size_t)idx * stride;
                    stride *= (size_t)size[i];
                }
                if (w == 0)
                    continue;
                size_t s = index * (size_t)n + (size_t)k;
                acc += w * (s < samples.size() ? samples[s] : 0);
            }
            double maxv = pow(2, bps) - 1;
            double d0 = decode.size() > (size_t)2 * k + 1 ? decode[2 * k] : range[2 * k];
            double d1 = decode.size() > (size_t)2 * k + 1 ? decode[2 * k + 1] : range[2 * k + 1];
            out[k] = d0 + acc * (d1 - d0) / maxv;
        }
        break;
    }
    case 2:
        for (int k = 0; k < n; k++) {
            double a = k < (int)c0.size() ? c0[k] : 0, b = k < (int)c1.size() ? c1[k] : 1;
            out[k] = a + pow(x[0], N) * (b - a);
        }
        break;
    case 3: {
        size_t i = 0;
        while (i < bounds.size() && x[0] >= bounds[i])
            i++;
        if (i >= parts.size()) {
            for (int k = 0; k < n; k++)
                out[k] = 0;
            break;
        }
        double lo = i == 0 ? domain[0] : bounds[i - 1], hi = i < bounds.size() ? bounds[i] : domain[1];
        double e0 = encode.size() > 2 * i + 1 ? encode[2 * i] : 0, e1 = encode.size() > 2 * i + 1 ? encode[2 * i + 1] : 1;
        double t = hi != lo ? e0 + (x[0] - lo) * (e1 - e0) / (hi - lo) : e0;
        parts[i]->eval(&t, out);
        break;
    }
    case 4: {
        std::vector<double> st(x, x + m);
        size_t pc = code.size() && code[0] == "{" ? 1 : 0;
        run_ps(code, pc, st, 0);
        for (int k = 0; k < n; k++) {
            size_t idx = st.size() >= (size_t)n ? st.size() - (size_t)n + (size_t)k : (size_t)k;
            out[k] = idx < st.size() ? st[idx] : 0;
        }
        break;
    }
    default:
        for (int k = 0; k < n; k++)
            out[k] = 0;
    }
    if (type != 3 || !range.empty())
        for (int k = 0; k < n && (size_t)2 * k + 1 < range.size(); k++)
            out[k] = fmin(range[2 * k + 1], fmax(range[2 * k], out[k]));
}

static std::unique_ptr<Function>
parse_function(CGPDFObjectRef o, int depth)
{
    CGPDFDictionaryRef d = object_dict(o);
    CGPDFInteger type;
    if (!d || depth > 8 || !CGPDFDictionaryGetInteger(d, "FunctionType", &type))
        return nullptr;
    auto f = std::make_unique<Function>();
    f->type = (int)type;
    if (!dict_numbers(d, "Domain", f->domain) || f->domain.size() < 2)
        f->domain = {0, 1};
    dict_numbers(d, "Range", f->range);
    switch (type) {
    case 0: {
        CGPDFStreamRef s;
        Vec size;
        if (!CGPDFObjectGetValue(o, kCGPDFObjectTypeStream, &s) || !dict_numbers(d, "Size", size) || f->range.empty())
            return nullptr;
        for (double v : size)
            f->size.push_back(std::max(1, (int)v));
        f->bps = (int)dict_number(d, "BitsPerSample", 8);
        dict_numbers(d, "Encode", f->encode);
        dict_numbers(d, "Decode", f->decode);
        std::vector<uint8_t> data = stream_bytes(s);
        size_t total = (f->range.size() / 2);
        for (int n : f->size)
            total *= (size_t)n;
        if (total > (1 << 24))
            return nullptr;
        size_t bit = 0;
        for (size_t i = 0; i < total; i++) {
            uint64_t v = 0;
            for (int b = 0; b < f->bps; b++, bit++) {
                size_t byte = bit / 8;
                int on = byte < data.size() ? (data[byte] >> (7 - bit % 8)) & 1 : 0;
                v = v << 1 | (uint64_t)on;
            }
            f->samples.push_back((double)v);
        }
        break;
    }
    case 2:
        if (!dict_numbers(d, "C0", f->c0))
            f->c0 = {0};
        if (!dict_numbers(d, "C1", f->c1))
            f->c1 = {1};
        f->N = dict_number(d, "N", 1);
        break;
    case 3: {
        CGPDFArrayRef fns;
        if (!CGPDFDictionaryGetArray(d, "Functions", &fns))
            return nullptr;
        for (size_t i = 0; i < CGPDFArrayGetCount(fns); i++) {
            CGPDFObjectRef fo;
            if (!CGPDFArrayGetObject(fns, i, &fo))
                return nullptr;
            auto part = parse_function(fo, depth + 1);
            if (!part)
                return nullptr;
            f->parts.push_back(std::move(part));
        }
        dict_numbers(d, "Bounds", f->bounds);
        dict_numbers(d, "Encode", f->encode);
        if (f->parts.empty())
            return nullptr;
        break;
    }
    case 4: {
        CGPDFStreamRef s;
        if (!CGPDFObjectGetValue(o, kCGPDFObjectTypeStream, &s))
            return nullptr;
        tokenize_ps(stream_bytes(s), f->code);
        break;
    }
    default: return nullptr;
    }
    return f;
}

/* A /Function entry: one function, or an array of 1-output functions. */
struct FunctionSet {
    std::vector<std::unique_ptr<Function>> fns;
    int outputs() const
    {
        if (fns.size() == 1)
            return fns[0]->outputs();
        return (int)fns.size();
    }
    void eval(const double *in, double *out) const
    {
        if (fns.size() == 1) {
            fns[0]->eval(in, out);
            return;
        }
        for (size_t i = 0; i < fns.size(); i++) {
            double v[32] = {0};
            fns[i]->eval(in, v);
            out[i] = v[0];
        }
    }
    bool empty() const { return fns.empty(); }
};

static FunctionSet
parse_functions(CGPDFObjectRef o)
{
    FunctionSet set;
    CGPDFArrayRef a;
    if (CGPDFObjectGetValue(o, kCGPDFObjectTypeArray, &a)) {
        for (size_t i = 0; i < CGPDFArrayGetCount(a); i++) {
            CGPDFObjectRef fo;
            std::unique_ptr<Function> f;
            if (CGPDFArrayGetObject(a, i, &fo))
                f = parse_function(fo);
            if (!f)
                return FunctionSet();
            set.fns.push_back(std::move(f));
        }
    } else if (auto f = parse_function(o)) {
        set.fns.push_back(std::move(f));
    }
    return set;
}

#pragma mark - Colour spaces (section 8.6)

struct ColorSpace {
    enum Kind { Gray, RGB, CMYK, CalGray, CalRGB, Lab, ICC, Indexed, Separation, DeviceN, Pattern } kind = Gray;
    int n = 1;                          /* components a colour in it has */
    CGColorSpaceRef cg = NULL;          /* where colours land (the base or alternate for the others) */
    std::shared_ptr<ColorSpace> base;   /* Indexed's base, Separation/DeviceN's alternate, Pattern's underlying */
    std::vector<uint8_t> lookup;
    int hival = 0;
    FunctionSet tint;
    Vec range;                          /* Lab's a* b* range */
    ~ColorSpace()
    {
        if (cg)
            CFRelease(cg);
    }
    /* Components in this space to components in `cg`, as CG wants them. */
    void convert(const double *in, CGFloat *out) const
    {
        switch (kind) {
        case Indexed: {
            int i = (int)fmin(hival, fmax(0, floor(in[0] + 0.5)));
            double v[32];
            for (int k = 0; k < base->n; k++) {
                size_t at = (size_t)i * (size_t)base->n + (size_t)k;
                v[k] = at < lookup.size() ? lookup[at] / 255.0 : 0;
                if (base->kind == Lab && k > 0 && base->range.size() == 4)
                    v[k] = base->range[2 * (k - 1)] + v[k] * (base->range[2 * k - 1] - base->range[2 * (k - 1)]);
                else if (base->kind == Lab && k == 0)
                    v[k] *= 100;
            }
            base->convert(v, out);
            break;
        }
        case Separation:
        case DeviceN: {
            double v[32] = {0};
            if (!tint.empty())
                tint.eval(in, v);
            base->convert(v, out);
            break;
        }
        default:
            for (int k = 0; k < n; k++)
                out[k] = in[k];
        }
    }
    size_t cg_components() const { return cg ? CGColorSpaceGetNumberOfComponents(cg) : 1; }
    /* The initial colour (section 8.6.5.x). */
    void initial(Vec &out) const
    {
        out.assign((size_t)n, 0);
        if (kind == CMYK)
            out[3] = 1;
        if (kind == Separation || kind == DeviceN)
            out.assign((size_t)n, 1);
        if (kind == Lab)
            out[0] = 0;
    }
};

typedef std::shared_ptr<ColorSpace> CSRef;

static CSRef
device_space(const char *name)
{
    auto cs = std::make_shared<ColorSpace>();
    if (!strcmp(name, "DeviceGray") || !strcmp(name, "G") || !strcmp(name, "CalGray")) {
        cs->kind = ColorSpace::Gray, cs->n = 1, cs->cg = CGColorSpaceCreateDeviceGray();
    } else if (!strcmp(name, "DeviceRGB") || !strcmp(name, "RGB") || !strcmp(name, "CalRGB")) {
        cs->kind = ColorSpace::RGB, cs->n = 3, cs->cg = CGColorSpaceCreateDeviceRGB();
    } else if (!strcmp(name, "DeviceCMYK") || !strcmp(name, "CMYK")) {
        cs->kind = ColorSpace::CMYK, cs->n = 4, cs->cg = CGColorSpaceCreateDeviceCMYK();
    } else if (!strcmp(name, "Pattern")) {
        cs->kind = ColorSpace::Pattern, cs->n = 0;
    } else {
        return nullptr;
    }
    return cs;
}

static CSRef parse_space(CGPDFObjectRef o, CGPDFDictionaryRef resources, int depth);

static CSRef
space_by_n(int n)
{
    return device_space(n == 1 ? "DeviceGray" : n == 4 ? "DeviceCMYK" : "DeviceRGB");
}

static CSRef
parse_space(CGPDFObjectRef o, CGPDFDictionaryRef resources, int depth)
{
    if (!o || depth > 8)
        return nullptr;
    const char *name;
    if (CGPDFObjectGetValue(o, kCGPDFObjectTypeName, &name)) {
        if (CSRef cs = device_space(name))
            return cs;
        /* a named space in the resources */
        CGPDFDictionaryRef spaces;
        CGPDFObjectRef r;
        if (resources && CGPDFDictionaryGetDictionary(resources, "ColorSpace", &spaces) &&
            CGPDFDictionaryGetObject(spaces, name, &r))
            return parse_space(r, NULL, depth + 1);
        return nullptr;
    }
    CGPDFArrayRef a;
    if (!CGPDFObjectGetValue(o, kCGPDFObjectTypeArray, &a) || !CGPDFArrayGetName(a, 0, &name))
        return nullptr;
    auto cs = std::make_shared<ColorSpace>();
    CGPDFDictionaryRef params = NULL;
    CGPDFArrayGetDictionary(a, 1, &params);
    if (!strcmp(name, "CalGray") || !strcmp(name, "CalRGB") || !strcmp(name, "Lab")) {
        Vec white, black, gamma, matrix, range;
        if (!dict_numbers(params, "WhitePoint", white) || white.size() != 3)
            white = {0.9505, 1, 1.089};
        if (!dict_numbers(params, "BlackPoint", black) || black.size() != 3)
            black = {0, 0, 0};
        CGFloat w[3] = {white[0], white[1], white[2]}, b[3] = {black[0], black[1], black[2]};
        if (!strcmp(name, "CalGray")) {
            cs->kind = ColorSpace::CalGray, cs->n = 1;
            cs->cg = CGColorSpaceCreateCalibratedGray(w, b, dict_number(params, "Gamma", 1));
        } else if (!strcmp(name, "CalRGB")) {
            cs->kind = ColorSpace::CalRGB, cs->n = 3;
            CGFloat g[3] = {1, 1, 1}, m[9] = {1, 0, 0, 0, 1, 0, 0, 0, 1};
            if (dict_numbers(params, "Gamma", gamma) && gamma.size() == 3)
                for (int i = 0; i < 3; i++)
                    g[i] = gamma[i];
            if (dict_numbers(params, "Matrix", matrix) && matrix.size() == 9)
                for (int i = 0; i < 9; i++)
                    m[i] = matrix[i];
            cs->cg = CGColorSpaceCreateCalibratedRGB(w, b, g, m);
        } else {
            cs->kind = ColorSpace::Lab, cs->n = 3;
            if (!dict_numbers(params, "Range", range) || range.size() != 4)
                range = {-100, 100, -100, 100};
            cs->range = range;
            CGFloat r[4] = {range[0], range[1], range[2], range[3]};
            cs->cg = CGColorSpaceCreateLab(w, b, r);
        }
        if (!cs->cg)
            return space_by_n(cs->n);
        return cs;
    }
    if (!strcmp(name, "ICCBased")) {
        CGPDFStreamRef s;
        if (!CGPDFArrayGetStream(a, 1, &s))
            return nullptr;
        CGPDFDictionaryRef sd = CGPDFStreamGetDictionary(s);
        CGPDFInteger n = 0;
        CGPDFDictionaryGetInteger(sd, "N", &n);
        std::vector<uint8_t> icc = stream_bytes(s);
        CFDataRef data = CFDataCreate(NULL, icc.data(), (CFIndex)icc.size());
        CGColorSpaceRef cg = CGColorSpaceCreateWithICCData(data);
        CFRelease(data);
        if (cg && (n == 0 || (CGPDFInteger)CGColorSpaceGetNumberOfComponents(cg) == n)) {
            cs->kind = ColorSpace::ICC;
            cs->n = (int)CGColorSpaceGetNumberOfComponents(cg);
            cs->cg = cg;
            return cs;
        }
        if (cg)
            CFRelease(cg);
        CGPDFObjectRef alt;
        if (CGPDFDictionaryGetObject(sd, "Alternate", &alt))
            if (CSRef r = parse_space(alt, resources, depth + 1))
                return r;
        return space_by_n((int)n);
    }
    if (!strcmp(name, "Indexed") || !strcmp(name, "I")) {
        CGPDFObjectRef bo;
        CGPDFInteger hival = 0;
        if (!CGPDFArrayGetObject(a, 1, &bo) || !CGPDFArrayGetInteger(a, 2, &hival))
            return nullptr;
        cs->base = parse_space(bo, resources, depth + 1);
        if (!cs->base || cs->base->kind == ColorSpace::Pattern || cs->base->kind == ColorSpace::Indexed)
            return nullptr;
        cs->kind = ColorSpace::Indexed, cs->n = 1;
        cs->hival = (int)std::min<CGPDFInteger>(255, std::max<CGPDFInteger>(0, hival));
        CGPDFStringRef str;
        CGPDFStreamRef st;
        if (CGPDFArrayGetString(a, 3, &str))
            cs->lookup.assign(CGPDFStringGetBytePtr(str), CGPDFStringGetBytePtr(str) + CGPDFStringGetLength(str));
        else if (CGPDFArrayGetStream(a, 3, &st))
            cs->lookup = stream_bytes(st);
        cs->cg = cs->base->cg ? (CGColorSpaceRef)CFRetain(cs->base->cg) : NULL;
        return cs;
    }
    if (!strcmp(name, "Separation") || !strcmp(name, "DeviceN")) {
        bool sep = !strcmp(name, "Separation");
        CGPDFObjectRef ao, to;
        if (!CGPDFArrayGetObject(a, 2, &ao) || !CGPDFArrayGetObject(a, 3, &to))
            return nullptr;
        cs->kind = sep ? ColorSpace::Separation : ColorSpace::DeviceN;
        CGPDFArrayRef names;
        if (sep) {
            cs->n = 1;  /* (a /None colorant paints through its alternate, as Apple's does) */
        } else {
            cs->n = CGPDFArrayGetArray(a, 1, &names) ? (int)CGPDFArrayGetCount(names) : 1;
            cs->n = std::max(1, std::min(cs->n, 32));
        }
        cs->base = parse_space(ao, resources, depth + 1);
        if (!cs->base || cs->base->kind == ColorSpace::Pattern)
            return nullptr;
        cs->tint = parse_functions(to);
        cs->cg = cs->base->cg ? (CGColorSpaceRef)CFRetain(cs->base->cg) : NULL;
        return cs;
    }
    if (!strcmp(name, "Pattern")) {
        cs->kind = ColorSpace::Pattern, cs->n = 0;
        CGPDFObjectRef bo;
        if (CGPDFArrayGetObject(a, 1, &bo))
            cs->base = parse_space(bo, resources, depth + 1);
        return cs;
    }
    if (CSRef d = device_space(name))
        return d;
    return nullptr;
}

#pragma mark - Glyph names and the standard encodings (Annex D)

/* The standard Latin character sets, by code; the rest of each table is undefined. */
static const char *const standard_high[] = {
    /* 161 */ "exclamdown", "cent", "sterling", "fraction", "yen", "florin", "section", "currency", "quotesingle",
    "quotedblleft", "guillemotleft", "guilsinglleft", "guilsinglright", "fi", "fl", NULL, "endash", "dagger",
    "daggerdbl", "periodcentered", NULL, "paragraph", "bullet", "quotesinglbase", "quotedblbase", "quotedblright",
    "guillemotright", "ellipsis", "perthousand", NULL, "questiondown", NULL, "grave", "acute", "circumflex", "tilde",
    "macron", "breve", "dotaccent", "dieresis", NULL, "ring", "cedilla", NULL, "hungarumlaut", "ogonek", "caron",
    "emdash", /* 209-224 */ NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
    NULL, NULL, /* 225 */ "AE", NULL, "ordfeminine", NULL, NULL, NULL, NULL, "Lslash", "Oslash", "OE",
    "ordmasculine", NULL, NULL, NULL, NULL, NULL, "ae", NULL, NULL, NULL, "dotlessi", NULL, NULL, "lslash", "oslash",
    "oe", "germandbls",
};

static const char *const ascii_names[] = {
    /* 32 */ "space", "exclam", "quotedbl", "numbersign", "dollar", "percent", "ampersand", "quoteright", "parenleft",
    "parenright", "asterisk", "plus", "comma", "hyphen", "period", "slash", "zero", "one", "two", "three", "four",
    "five", "six", "seven", "eight", "nine", "colon", "semicolon", "less", "equal", "greater", "question", "at", "A",
    "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M", "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X",
    "Y", "Z", "bracketleft", "backslash", "bracketright", "asciicircum", "underscore", "quoteleft", "a", "b", "c",
    "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
    "braceleft", "bar", "braceright", "asciitilde",
};

static const char *const latin1_names[] = {
    /* 160 */ "space", "exclamdown", "cent", "sterling", "currency", "yen", "brokenbar", "section", "dieresis",
    "copyright", "ordfeminine", "guillemotleft", "logicalnot", "hyphen", "registered", "macron", "degree",
    "plusminus", "twosuperior", "threesuperior", "acute", "mu", "paragraph", "periodcentered", "cedilla",
    "onesuperior", "ordmasculine", "guillemotright", "onequarter", "onehalf", "threequarters", "questiondown",
    "Agrave", "Aacute", "Acircumflex", "Atilde", "Adieresis", "Aring", "AE", "Ccedilla", "Egrave", "Eacute",
    "Ecircumflex", "Edieresis", "Igrave", "Iacute", "Icircumflex", "Idieresis", "Eth", "Ntilde", "Ograve", "Oacute",
    "Ocircumflex", "Otilde", "Odieresis", "multiply", "Oslash", "Ugrave", "Uacute", "Ucircumflex", "Udieresis",
    "Yacute", "Thorn", "germandbls", "agrave", "aacute", "acircumflex", "atilde", "adieresis", "aring", "ae",
    "ccedilla", "egrave", "eacute", "ecircumflex", "edieresis", "igrave", "iacute", "icircumflex", "idieresis", "eth",
    "ntilde", "ograve", "oacute", "ocircumflex", "otilde", "odieresis", "divide", "oslash", "ugrave", "uacute",
    "ucircumflex", "udieresis", "yacute", "thorn", "ydieresis",
};

static const char *const winansi_80[] = {
    "Euro", NULL, "quotesinglbase", "florin", "quotedblbase", "ellipsis", "dagger", "daggerdbl", "circumflex",
    "perthousand", "Scaron", "guilsinglleft", "OE", NULL, "Zcaron", NULL, NULL, "quoteleft", "quoteright",
    "quotedblleft", "quotedblright", "bullet", "endash", "emdash", "tilde", "trademark", "scaron", "guilsinglright",
    "oe", NULL, "zcaron", "Ydieresis",
};

static const char *const macroman_80[] = {
    "Adieresis", "Aring", "Ccedilla", "Eacute", "Ntilde", "Odieresis", "Udieresis", "aacute", "agrave",
    "acircumflex", "adieresis", "atilde", "aring", "ccedilla", "eacute", "egrave", "ecircumflex", "edieresis",
    "iacute", "igrave", "icircumflex", "idieresis", "ntilde", "oacute", "ograve", "ocircumflex", "odieresis",
    "otilde", "uacute", "ugrave", "ucircumflex", "udieresis", "dagger", "degree", "cent", "sterling", "section",
    "bullet", "paragraph", "germandbls", "registered", "copyright", "trademark", "acute", "dieresis", "notequal",
    "AE", "Oslash", "infinity", "plusminus", "lessequal", "greaterequal", "yen", "mu", "partialdiff", "summation",
    "product", "pi", "integral", "ordfeminine", "ordmasculine", "Omega", "ae", "oslash", "questiondown",
    "exclamdown", "logicalnot", "radical", "florin", "approxequal", "Delta", "guillemotleft", "guillemotright",
    "ellipsis", "space", "Agrave", "Atilde", "Otilde", "OE", "oe", "endash", "emdash", "quotedblleft",
    "quotedblright", "quoteleft", "quoteright", "divide", "lozenge", "ydieresis", "Ydieresis", "fraction",
    "currency", "guilsinglleft", "guilsinglright", "fi", "fl", "daggerdbl", "periodcentered", "quotesinglbase",
    "quotedblbase", "perthousand", "Acircumflex", "Ecircumflex", "Aacute", "Edieresis", "Egrave", "Iacute",
    "Icircumflex", "Idieresis", "Igrave", "Oacute", "Ocircumflex", "apple", "Ograve", "Uacute", "Ucircumflex",
    "Ugrave", "dotlessi", "circumflex", "tilde", "macron", "breve", "dotaccent", "ring", "cedilla", "hungarumlaut",
    "ogonek", "caron",
};

enum { ENC_STANDARD, ENC_WINANSI, ENC_MACROMAN, ENC_NONE };

static const char *
encoding_name(int enc, int code)
{
    if (code >= 32 && code <= 126) {
        if (enc != ENC_STANDARD && code == 39)
            return "quotesingle";
        if (enc != ENC_STANDARD && code == 96)
            return "grave";
        return ascii_names[code - 32];
    }
    switch (enc) {
    case ENC_STANDARD: return code >= 161 && code <= 251 ? standard_high[code - 161] : NULL;
    case ENC_WINANSI:
        if (code >= 128 && code < 160)
            return winansi_80[code - 128];
        if (code == 127)
            return "bullet";
        return code >= 160 ? latin1_names[code - 160] : NULL;
    case ENC_MACROMAN: return code >= 128 ? macroman_80[code - 128] : NULL;
    }
    return NULL;
}

/* A glyph name's Unicode value: the standard Latin names, "uniXXXX", "uXXXX[XX]". */
static uint32_t
name_to_unicode(const char *name)
{
    static std::unordered_map<std::string, uint32_t> *table;
    static pthread_once_t once = PTHREAD_ONCE_INIT;
    pthread_once(&once, [] {
        table = new std::unordered_map<std::string, uint32_t>();
        const struct {
            int enc;
            CFStringEncoding cf;
        } sets[] = {{ENC_WINANSI, kCFStringEncodingWindowsLatin1}, {ENC_MACROMAN, kCFStringEncodingMacRoman}};
        for (auto &set : sets)
            for (int code = 32; code < 256; code++) {
                const char *n = encoding_name(set.enc, code);
                if (!n || table->count(n))
                    continue;
                uint8_t b = (uint8_t)code;
                CFStringRef s = CFStringCreateWithBytes(NULL, &b, 1, set.cf, false);
                if (s && CFStringGetLength(s) == 1)
                    (*table)[n] = CFStringGetCharacterAtIndex(s, 0);
                if (s)
                    CFRelease(s);
            }
        (*table)["space"] = 0x20;
        (*table)["quotesingle"] = 0x27;
        (*table)["grave"] = 0x60;
        (*table)["Lslash"] = 0x141, (*table)["lslash"] = 0x142, (*table)["minus"] = 0x2212;
        (*table)["nbspace"] = 0xA0, (*table)["sfthyphen"] = 0xAD, (*table)["fraction"] = 0x2044;
        (*table)["hungarumlaut"] = 0x2DD, (*table)["ogonek"] = 0x2DB, (*table)["caron"] = 0x2C7;
        (*table)["breve"] = 0x2D8, (*table)["dotaccent"] = 0x2D9, (*table)["ring"] = 0x2DA;
        (*table)["fi"] = 0xFB01, (*table)["fl"] = 0xFB02, (*table)["dotlessi"] = 0x131;
    });
    auto it = table->find(name);
    if (it != table->end())
        return it->second;
    size_t len = strlen(name);
    if (len == 7 && !strncmp(name, "uni", 3))
        return (uint32_t)strtoul(name + 3, NULL, 16);
    if ((len == 5 || len == 6 || len == 7) && name[0] == 'u')
        return (uint32_t)strtoul(name + 1, NULL, 16);
    return 0;
}

#pragma mark - Fonts (section 9.5 onwards)

struct CMapRange {
    uint32_t lo, hi;
    int bytes;
};

struct Font {
    enum { Simple, Type0, Type3 } kind = Simple;
    CGFontRef cg = NULL;
    FT_Face face = NULL;
    bool truetype = false, symbolic = false, embedded = false;
    /* simple fonts */
    int glyph[256];
    double widths[256];
    bool has_width[256];
    double missing_width = 0;
    /* Type 0 */
    std::vector<CMapRange> codespace;
    std::vector<std::pair<std::pair<uint32_t, uint32_t>, uint32_t>> cid_ranges;  /* (lo, hi) -> first CID */
    bool identity = true;
    std::vector<uint16_t> cid_to_gid;
    bool cid_gid_identity = true;
    std::unordered_map<uint32_t, double> cid_widths;
    double default_width = 1000;
    bool vertical = false;
    /* Type 3 */
    CGAffineTransform font_matrix = CGAffineTransformMake(0.001, 0, 0, 0.001, 0, 0);
    CGPDFDictionaryRef char_procs = NULL, resources = NULL;
    const char *names[256];
    ~Font()
    {
        if (cg)
            CFRelease(cg);
    }
    /* The next character code in `s` at `i`, and how many bytes it took. */
    uint32_t next(const uint8_t *s, size_t n, size_t &i, int &bytes) const;
    uint32_t cid_of(uint32_t code) const;
    double width(uint32_t code) const;  /* in text space units per unit font size, before Tc/Tw */
    int glyph_of(uint32_t code) const;
};

uint32_t
Font::next(const uint8_t *s, size_t n, size_t &i, int &bytes) const
{
    if (kind != Type0) {
        bytes = 1;
        return s[i++];
    }
    if (codespace.empty()) {
        bytes = i + 1 < n ? 2 : 1;
        uint32_t c = bytes == 2 ? (uint32_t)(s[i] << 8 | s[i + 1]) : s[i];
        i += (size_t)bytes;
        return c;
    }
    uint32_t c = 0;
    for (int k = 1; k <= 4 && i + (size_t)k <= n; k++) {
        c = c << 8 | s[i + (size_t)k - 1];
        for (const CMapRange &r : codespace)
            if (r.bytes == k && c >= r.lo && c <= r.hi) {
                i += (size_t)k;
                bytes = k;
                return c;
            }
    }
    /* not in any range: the shortest code length */
    int k = 4;
    for (const CMapRange &r : codespace)
        k = std::min(k, r.bytes);
    c = 0;
    for (int j = 0; j < k && i < n; j++)
        c = c << 8 | s[i++];
    bytes = k;
    return c;
}

uint32_t
Font::cid_of(uint32_t code) const
{
    if (identity)
        return code;
    for (auto &r : cid_ranges)
        if (code >= r.first.first && code <= r.first.second)
            return r.second + (code - r.first.first);
    return 0;
}

double
Font::width(uint32_t code) const
{
    if (kind == Type0) {
        auto it = cid_widths.find(cid_of(code));
        return (it != cid_widths.end() ? it->second : default_width) / 1000;
    }
    if (code < 256 && has_width[code])
        return kind == Type3 ? widths[code] * font_matrix.a : widths[code] / 1000;
    if (kind == Type3)
        return 0;
    /* the font's own advance */
    int g = glyph_of(code);
    if (cg && g > 0) {
        int adv = 0;
        CGGlyph gl = (CGGlyph)g;
        CGFontGetGlyphAdvances(cg, &gl, 1, &adv);
        return (double)adv / CGFontGetUnitsPerEm(cg);
    }
    return missing_width / 1000;
}

int
Font::glyph_of(uint32_t code) const
{
    if (kind == Type0) {
        uint32_t cid = cid_of(code);
        if (!cid_gid_identity)
            return cid < cid_to_gid.size() ? cid_to_gid[cid] : 0;
        return (int)cid;
    }
    return code < 256 ? glyph[code] : 0;
}

static bool
has_cmap(FT_Face face, int platform, int encoding)
{
    for (int i = 0; i < face->num_charmaps; i++)
        if (face->charmaps[i]->platform_id == platform && face->charmaps[i]->encoding_id == encoding) {
            FT_Set_Charmap(face, face->charmaps[i]);
            return true;
        }
    return false;
}

/* Fonts that aren't embedded: the standard 14 and others, by family. */
static CGFontRef
substitute_font(const char *base)
{
    std::string name = base ? base : "Helvetica";
    if (name.size() > 7 && name[6] == '+')
        name = name.substr(7);
    std::vector<std::string> tries = {name};
    bool bold = name.find("Bold") != std::string::npos || name.find("bold") != std::string::npos;
    bool italic = name.find("Italic") != std::string::npos || name.find("Oblique") != std::string::npos;
    std::string family = "Helvetica";
    if (name.find("Times") != std::string::npos || name.find("Serif") != std::string::npos ||
        name.find("Georgia") != std::string::npos)
        family = "Times";
    else if (name.find("Courier") != std::string::npos || name.find("Mono") != std::string::npos)
        family = "Courier";
    else if (name.find("Symbol") != std::string::npos)
        family = "Symbol";
    else if (name.find("Dingbats") != std::string::npos)
        family = "ZapfDingbats";
    if (family == "Times")
        tries.push_back(bold && italic ? "Times-BoldItalic" : bold ? "Times-Bold" : italic ? "Times-Italic" : "Times-Roman");
    else if (family == "Courier")
        tries.push_back(bold && italic ? "Courier-BoldOblique" : bold ? "Courier-Bold" : italic ? "Courier-Oblique" : "Courier");
    else if (family == "Helvetica")
        tries.push_back(bold && italic ? "Helvetica-BoldOblique" : bold ? "Helvetica-Bold" : italic ? "Helvetica-Oblique" : "Helvetica");
    else
        tries.push_back(family);
    tries.push_back(family == "Times" ? "LiberationSerif" : family == "Courier" ? "LiberationMono" : "LiberationSans");
    tries.push_back("Helvetica");
    tries.push_back("ArialMT");
    for (auto &t : tries) {
        CFStringRef n = CFStringCreateWithCString(NULL, t.c_str(), kCFStringEncodingUTF8);
        CGFontRef f = CGFontCreateWithFontName(n);
        CFRelease(n);
        if (f)
            return f;
    }
    return NULL;
}

static CGFontRef
embedded_font(CGPDFDictionaryRef descriptor, bool &truetype)
{
    static const char *keys[] = {"FontFile2", "FontFile3", "FontFile"};
    for (int k = 0; k < 3 && descriptor; k++) {
        CGPDFStreamRef s;
        if (!CGPDFDictionaryGetStream(descriptor, keys[k], &s))
            continue;
        std::vector<uint8_t> data = stream_bytes(s);
        CFDataRef d = CFDataCreate(NULL, data.data(), (CFIndex)data.size());
        CGDataProviderRef p = CGDataProviderCreateWithCFData(d);
        CFRelease(d);
        CGFontRef f = CGFontCreateWithDataProvider(p);
        CGDataProviderRelease(p);
        if (f) {
            FT_ULong len = 0;
            truetype = k == 0 || (f->face && FT_IS_SFNT((FT_Face)f->face) &&
                                  FT_Load_Sfnt_Table((FT_Face)f->face, FT_MAKE_TAG('g', 'l', 'y', 'f'), 0, NULL, &len) == 0);
            return f;
        }
    }
    return NULL;
}

/* An embedded CMap's code space and CID mappings (section 9.7.5). */
static void
parse_cmap(CGPDFStreamRef s, Font &f)
{
    std::vector<uint8_t> data = stream_bytes(s);
    CGPDFArena arena;
    CGPDFContentReader r(data.data(), data.size(), arena, NULL);
    CGPDFOperation op;
    std::vector<CGPDFObject> pending;
    auto code_of = [](const CGPDFObject &o, int &bytes) {
        uint32_t v = 0;
        bytes = 0;
        if (o.type == kCGPDFObjectTypeString)
            for (size_t i = 0; i < o.string->length && i < 4; i++)
                v = v << 8 | o.string->bytes[i], bytes++;
        return v;
    };
    /* the reader stops at keywords: "begincodespacerange" etc. arrive as operations */
    std::string mode;
    while (r.next(op)) {
        std::string k = op.op;
        if (k == "begincodespacerange" || k == "begincidrange" || k == "begincidchar") {
            mode = k;
            continue;
        }
        if (k == "endcodespacerange") {
            for (size_t i = 0; i + 1 < op.operands.size(); i += 2) {
                int b1, b2;
                uint32_t lo = code_of(op.operands[i], b1), hi = code_of(op.operands[i + 1], b2);
                if (b1)
                    f.codespace.push_back(CMapRange{lo, hi, b1});
            }
        } else if (k == "endcidrange") {
            for (size_t i = 0; i + 2 < op.operands.size(); i += 3) {
                int b;
                uint32_t lo = code_of(op.operands[i], b), hi = code_of(op.operands[i + 1], b);
                if (op.operands[i + 2].type == kCGPDFObjectTypeInteger)
                    f.cid_ranges.push_back({{lo, hi}, (uint32_t)op.operands[i + 2].i});
            }
            f.identity = false;
        } else if (k == "endcidchar") {
            for (size_t i = 0; i + 1 < op.operands.size(); i += 2) {
                int b;
                uint32_t c = code_of(op.operands[i], b);
                if (op.operands[i + 1].type == kCGPDFObjectTypeInteger)
                    f.cid_ranges.push_back({{c, c}, (uint32_t)op.operands[i + 1].i});
            }
            f.identity = false;
        }
        mode.clear();
    }
}

static std::unique_ptr<Font>
load_font(CGPDFDictionaryRef fd)
{
    auto f = std::make_unique<Font>();
    const char *subtype = "Type1", *base = NULL;
    CGPDFDictionaryGetName(fd, "Subtype", &subtype);
    CGPDFDictionaryGetName(fd, "BaseFont", &base);
    for (int i = 0; i < 256; i++)
        f->glyph[i] = 0, f->widths[i] = 0, f->has_width[i] = false, f->names[i] = NULL;
    CGPDFDictionaryRef descriptor = NULL;
    if (!strcmp(subtype, "Type0")) {
        f->kind = Font::Type0;
        CGPDFArrayRef desc;
        CGPDFDictionaryRef cid = NULL;
        if (CGPDFDictionaryGetArray(fd, "DescendantFonts", &desc))
            CGPDFArrayGetDictionary(desc, 0, &cid);
        const char *enc = NULL;
        CGPDFStreamRef cmap;
        if (CGPDFDictionaryGetName(fd, "Encoding", &enc)) {
            f->vertical = !strcmp(enc, "Identity-V");
        } else if (CGPDFDictionaryGetStream(fd, "Encoding", &cmap)) {
            parse_cmap(cmap, *f);
            CGPDFInteger wmode = 0;
            CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(cmap), "WMode", &wmode);
            f->vertical = wmode == 1;
        }
        if (!cid)
            return f;
        CGPDFDictionaryGetDictionary(cid, "FontDescriptor", &descriptor);
        f->cg = embedded_font(descriptor, f->truetype);
        f->embedded = f->cg != NULL;
        if (!f->cg) {
            const char *b = base;
            CGPDFDictionaryGetName(cid, "BaseFont", &b);
            f->cg = substitute_font(b);
        }
        CGPDFStreamRef map;
        const char *mapname;
        if (CGPDFDictionaryGetStream(cid, "CIDToGIDMap", &map)) {
            std::vector<uint8_t> m = stream_bytes(map);
            for (size_t i = 0; i + 1 < m.size(); i += 2)
                f->cid_to_gid.push_back((uint16_t)(m[i] << 8 | m[i + 1]));
            f->cid_gid_identity = false;
        } else if (CGPDFDictionaryGetName(cid, "CIDToGIDMap", &mapname)) {
            f->cid_gid_identity = true;
        }
        f->default_width = dict_number(cid, "DW", 1000);
        CGPDFArrayRef w;
        if (CGPDFDictionaryGetArray(cid, "W", &w)) {
            /* c [w1 w2 ...] | c_first c_last w */
            size_t n = CGPDFArrayGetCount(w);
            for (size_t i = 0; i < n;) {
                CGPDFInteger first;
                if (!CGPDFArrayGetInteger(w, i, &first))
                    break;
                CGPDFArrayRef list;
                if (CGPDFArrayGetArray(w, i + 1, &list)) {
                    for (size_t k = 0; k < CGPDFArrayGetCount(list); k++) {
                        CGPDFReal v = 0;
                        CGPDFArrayGetNumber(list, k, &v);
                        f->cid_widths[(uint32_t)(first + (CGPDFInteger)k)] = v;
                    }
                    i += 2;
                } else {
                    CGPDFInteger last;
                    CGPDFReal v = 0;
                    if (!CGPDFArrayGetInteger(w, i + 1, &last) || !CGPDFArrayGetNumber(w, i + 2, &v))
                        break;
                    for (CGPDFInteger c = first; c <= last && c - first < 65536; c++)
                        f->cid_widths[(uint32_t)c] = v;
                    i += 3;
                }
            }
        }
        if (f->cg && !f->embedded && f->cg->face) {
            /* a substitute: CIDs mean nothing to it; keep them as glyph indices */
        }
        return f;
    }
    /* simple fonts: widths */
    CGPDFInteger first = 0;
    CGPDFDictionaryGetInteger(fd, "FirstChar", &first);
    CGPDFArrayRef widths;
    if (CGPDFDictionaryGetArray(fd, "Widths", &widths))
        for (size_t i = 0; i < CGPDFArrayGetCount(widths); i++) {
            CGPDFReal v = 0;
            long code = (long)first + (long)i;
            if (code >= 0 && code < 256 && CGPDFArrayGetNumber(widths, i, &v))
                f->widths[code] = v, f->has_width[code] = true;
        }
    CGPDFDictionaryGetDictionary(fd, "FontDescriptor", &descriptor);
    f->missing_width = dict_number(descriptor, "MissingWidth", 0);
    CGPDFInteger flags = 0;
    if (descriptor)
        CGPDFDictionaryGetInteger(descriptor, "Flags", &flags);
    f->symbolic = flags & 4;
    /* the encoding: a base and differences */
    int enc = ENC_NONE;
    const char *diffs[256] = {NULL};
    CGPDFObjectRef eo;
    const char *encname = NULL;
    if (CGPDFDictionaryGetObject(fd, "Encoding", &eo)) {
        CGPDFDictionaryRef ed;
        if (CGPDFObjectGetValue(eo, kCGPDFObjectTypeName, &encname)) {
        } else if (CGPDFObjectGetValue(eo, kCGPDFObjectTypeDictionary, &ed)) {
            CGPDFDictionaryGetName(ed, "BaseEncoding", &encname);
            CGPDFArrayRef d;
            if (CGPDFDictionaryGetArray(ed, "Differences", &d)) {
                int code = 0;
                for (size_t i = 0; i < CGPDFArrayGetCount(d); i++) {
                    CGPDFInteger c;
                    const char *n;
                    if (CGPDFArrayGetInteger(d, i, &c))
                        code = (int)c;
                    else if (CGPDFArrayGetName(d, i, &n) && code >= 0 && code < 256)
                        diffs[code++] = n;
                }
            }
        }
    }
    if (encname)
        enc = !strcmp(encname, "WinAnsiEncoding") ? ENC_WINANSI : !strcmp(encname, "MacRomanEncoding") ? ENC_MACROMAN
              : !strcmp(encname, "StandardEncoding") ? ENC_STANDARD : ENC_NONE;
    if (!strcmp(subtype, "Type3")) {
        f->kind = Font::Type3;
        f->font_matrix = matrix_of(fd, "FontMatrix");
        CGPDFDictionaryGetDictionary(fd, "CharProcs", &f->char_procs);
        CGPDFDictionaryGetDictionary(fd, "Resources", &f->resources);
        for (int c = 0; c < 256; c++)
            f->names[c] = diffs[c] ? diffs[c] : enc != ENC_NONE ? encoding_name(enc, c) : NULL;
        return f;
    }
    f->cg = embedded_font(descriptor, f->truetype);
    f->embedded = f->cg != NULL;
    if (!f->cg) {
        f->cg = substitute_font(base);
        f->truetype = false;
        if (enc == ENC_NONE && !f->symbolic)
            enc = ENC_STANDARD;
    }
    if (!f->cg)
        return f;
    FT_Face face = (FT_Face)f->cg->face;
    f->face = face;
    bool sfnt = FT_IS_SFNT(face);
    for (int code = 0; code < 256; code++) {
        const char *name = diffs[code] ? diffs[code] : enc != ENC_NONE ? encoding_name(enc, code) : NULL;
        f->names[code] = name;
        FT_UInt g = 0;
        if (sfnt && (f->truetype || !f->embedded)) {
            /* TrueType: through the font's cmap (section 9.6.6.4) */
            if (!g && name && has_cmap(face, 3, 1))
                if (uint32_t u = name_to_unicode(name))
                    g = FT_Get_Char_Index(face, u);
            if (!g && name && !f->embedded && face->charmap && face->charmap->encoding == FT_ENCODING_UNICODE)
                if (uint32_t u = name_to_unicode(name))
                    g = FT_Get_Char_Index(face, u);
            if (!g && has_cmap(face, 3, 0)) {
                g = FT_Get_Char_Index(face, 0xF000 + (FT_ULong)code);
                if (!g)
                    g = FT_Get_Char_Index(face, (FT_ULong)code);
            }
            if (!g && has_cmap(face, 1, 0)) {
                FT_ULong mc = (FT_ULong)code;
                if (name) {
                    for (int k = 0; k < 256; k++) {
                        const char *mn = encoding_name(ENC_MACROMAN, k);
                        if (mn && !strcmp(mn, name)) {
                            mc = (FT_ULong)k;
                            break;
                        }
                    }
                }
                g = FT_Get_Char_Index(face, mc);
            }
            if (!g && name && FT_HAS_GLYPH_NAMES(face))
                g = FT_Get_Name_Index(face, name);
            if (!g && !name && has_cmap(face, 3, 1))
                g = FT_Get_Char_Index(face, (FT_ULong)code);
        } else {
            /* Type 1 and CFF: by glyph name, or the font's built-in encoding */
            if (name)
                g = FT_Get_Name_Index(face, name);
            if (!g) {
                for (int i = 0; i < face->num_charmaps; i++) {
                    FT_Encoding e = face->charmaps[i]->encoding;
                    if (e == FT_ENCODING_ADOBE_CUSTOM || e == FT_ENCODING_ADOBE_STANDARD ||
                        e == FT_ENCODING_ADOBE_EXPERT || e == FT_ENCODING_ADOBE_LATIN_1) {
                        FT_Set_Charmap(face, face->charmaps[i]);
                        g = FT_Get_Char_Index(face, (FT_ULong)code);
                        break;
                    }
                }
            }
            if (!g && name && FT_Select_Charmap(face, FT_ENCODING_UNICODE) == 0)
                if (uint32_t u = name_to_unicode(name))
                    g = FT_Get_Char_Index(face, u);
        }
        f->glyph[code] = (int)g;
    }
    return f;
}

#pragma mark - The interpreter

struct State {
    CSRef fill_cs, stroke_cs;
    Vec fill, stroke;                        /* components in those spaces */
    CGPDFObjectRef fill_pattern = NULL, stroke_pattern = NULL;
    double fill_alpha = 1, stroke_alpha = 1;
    CGBlendMode blend = kCGBlendModeNormal;
    /* text state (section 9.3) */
    double Tc = 0, Tw = 0, Th = 1, TL = 0, Tfs = 0, rise = 0;
    int Tr = 0;
    Font *font = NULL;
    double line_width = 1;
    bool knockout = false;
};

struct Interp;
static void run_content(Interp &in, const uint8_t *bytes, size_t n);

struct Interp {
    CGContextRef c;
    CGPDFDocData *d;
    std::vector<State> stack;
    std::vector<CGPDFDictionaryRef> resources;
    std::vector<CGAffineTransform> pattern_base;   /* the default space of the stream being run */
    std::unordered_map<CGPDFDictionaryRef, std::unique_ptr<Font>> *fonts;
    CGAffineTransform Tm = CGAffineTransformIdentity, Tlm = CGAffineTransformIdentity;
    int pending_clip = 0;                          /* 1: nonzero, 2: even-odd */
    CGMutablePathRef text_clip = NULL;
    int depth = 0;
    bool uncolored = false;                        /* inside an uncoloured Type 3 glyph or pattern */
    int saves = 0;

    State &st() { return stack.back(); }

    CGPDFObjectRef resource(const char *category, const char *name)
    {
        CGPDFDictionaryRef r = resources.empty() ? NULL : resources.back(), cat;
        CGPDFObjectRef o;
        if (r && name && CGPDFDictionaryGetDictionary(r, category, &cat) && CGPDFDictionaryGetObject(cat, name, &o))
            return o;
        return NULL;
    }
};

static double
num(const CGPDFObject &o)
{
    return o.type == kCGPDFObjectTypeInteger ? (double)o.i : o.type == kCGPDFObjectTypeReal ? o.r : 0;
}

/* The CG colour for components in a space, with an alpha. */
static CGColorRef
make_color(const ColorSpace &cs, const Vec &v, double alpha)
{
    if (!cs.cg)
        return NULL;
    CGFloat out[CG_COLOR_MAX_COMPONENTS] = {0};
    double in[32] = {0};
    for (size_t i = 0; i < v.size() && i < 32; i++)
        in[i] = v[i];
    cs.convert(in, out);
    size_t n = cs.cg_components();
    out[n] = alpha;
    return CGColorCreate(cs.cg, out);
}

static void draw_shading(Interp &in, CGPDFDictionaryRef sh, bool as_pattern);
static void run_pattern_fill(Interp &in, CGPDFObjectRef pattern, bool stroke, CGPathRef path, bool eo);

static void
apply_colors(Interp &in)
{
    State &s = in.st();
    if (in.uncolored)
        return;
    if (s.fill_cs && s.fill_cs->kind != ColorSpace::Pattern)
        if (CGColorRef col = make_color(*s.fill_cs, s.fill, s.fill_alpha)) {
            CGContextSetFillColorWithColor(in.c, col);
            CGColorRelease(col);
        }
    if (s.stroke_cs && s.stroke_cs->kind != ColorSpace::Pattern)
        if (CGColorRef col = make_color(*s.stroke_cs, s.stroke, s.stroke_alpha)) {
            CGContextSetStrokeColorWithColor(in.c, col);
            CGColorRelease(col);
        }
}

static void
set_space(Interp &in, bool stroke, CGPDFObjectRef name_obj)
{
    CGPDFDictionaryRef res = in.resources.empty() ? NULL : in.resources.back();
    CSRef cs = parse_space(name_obj, res, 0);
    if (!cs)
        cs = device_space("DeviceGray");
    State &s = in.st();
    (stroke ? s.stroke_cs : s.fill_cs) = cs;
    cs->initial(stroke ? s.stroke : s.fill);
    (stroke ? s.stroke_pattern : s.fill_pattern) = NULL;
    apply_colors(in);
}

static void
set_device(Interp &in, bool stroke, const char *space, const std::vector<CGPDFObject> &ops)
{
    State &s = in.st();
    (stroke ? s.stroke_cs : s.fill_cs) = device_space(space);
    Vec &v = stroke ? s.stroke : s.fill;
    v.clear();
    for (auto &o : ops)
        v.push_back(num(o));
    (stroke ? s.stroke_pattern : s.fill_pattern) = NULL;
    apply_colors(in);
}

static void
set_components(Interp &in, bool stroke, const std::vector<CGPDFObject> &ops)
{
    State &s = in.st();
    Vec &v = stroke ? s.stroke : s.fill;
    CSRef cs = stroke ? s.stroke_cs : s.fill_cs;
    v.clear();
    for (auto &o : ops)
        if (o.type == kCGPDFObjectTypeInteger || o.type == kCGPDFObjectTypeReal)
            v.push_back(num(o));
    if (cs && cs->kind == ColorSpace::Pattern) {
        const char *name = NULL;
        if (!ops.empty() && ops.back().type == kCGPDFObjectTypeName)
            name = ops.back().name;
        (stroke ? s.stroke_pattern : s.fill_pattern) = in.resource("Pattern", name);
        return;
    }
    if (cs)
        v.resize((size_t)cs->n, 0);
    apply_colors(in);
}

#pragma mark - Painting

/* "n": end the path without painting it (but clipping, if W came first) */
static const CGPathDrawingMode kNoPaint = (CGPathDrawingMode)-1;

static void
paint(Interp &in, CGPathDrawingMode mode)
{
    CGContextRef c = in.c;
    State &s = in.st();
    if (mode == kNoPaint) {
        if (in.pending_clip == 2)
            CGContextEOClip(c);
        else if (in.pending_clip == 1)
            CGContextClip(c);
        CGContextBeginPath(c);
        in.pending_clip = 0;
        return;
    }
    bool fill = mode != kCGPathStroke, stroke = mode == kCGPathStroke || mode == kCGPathFillStroke ||
                                                mode == kCGPathEOFillStroke;
    bool eo = mode == kCGPathEOFill || mode == kCGPathEOFillStroke;
    CGPathRef path = CGContextCopyPath(c);
    bool fill_pattern = fill && !in.uncolored && s.fill_cs && s.fill_cs->kind == ColorSpace::Pattern;
    bool stroke_pattern = stroke && !in.uncolored && s.stroke_cs && s.stroke_cs->kind == ColorSpace::Pattern;
    if (path && !CGPathIsEmpty(path)) {
        if (fill_pattern || stroke_pattern) {
            CGContextBeginPath(c);
            if (fill) {
                if (fill_pattern) {
                    run_pattern_fill(in, s.fill_pattern, false, path, eo);
                } else {
                    CGContextAddPath(c, path);
                    CGContextDrawPath(c, eo ? kCGPathEOFill : kCGPathFill);
                }
            }
            if (stroke) {
                if (stroke_pattern) {
                    run_pattern_fill(in, s.stroke_pattern, true, path, false);
                } else {
                    CGContextAddPath(c, path);
                    CGContextDrawPath(c, kCGPathStroke);
                }
            }
        } else {
            CGContextDrawPath(c, mode);
        }
    }
    CGContextBeginPath(c);
    if (in.pending_clip && path) {
        CGContextAddPath(c, path);
        if (in.pending_clip == 2)
            CGContextEOClip(c);
        else
            CGContextClip(c);
    }
    in.pending_clip = 0;
    if (path)
        CFRelease(path);
}

#pragma mark - Images (section 8.9)

static CGImageRef image_from_stream(Interp &in, CGPDFStreamRef s, bool inline_image, bool *is_mask,
                                    bool as_smask = false);

static const char *
abbrev(CGPDFDictionaryRef d, const char *full, const char *shortk)
{
    return CGPDFDictionaryGetObject(d, full, NULL) ? full : shortk;
}

static CGImageRef
image_from_stream(Interp &in, CGPDFStreamRef s, bool inl, bool *is_mask, bool as_smask)
{
    CGPDFDictionaryRef d = CGPDFStreamGetDictionary(s);
    CGPDFInteger w = 0, h = 0, bpc = 8;
    CGPDFDictionaryGetInteger(d, abbrev(d, "Width", "W"), &w);
    CGPDFDictionaryGetInteger(d, abbrev(d, "Height", "H"), &h);
    if (w <= 0 || h <= 0 || w > 40000 || h > 40000)
        return NULL;
    CGPDFBoolean mask = 0, interp = 0;
    CGPDFDictionaryGetBoolean(d, abbrev(d, "ImageMask", "IM"), &mask);
    CGPDFDictionaryGetBoolean(d, abbrev(d, "Interpolate", "I"), &interp);
    *is_mask = mask && !as_smask;
    if (mask)
        bpc = 1;
    else
        CGPDFDictionaryGetInteger(d, abbrev(d, "BitsPerComponent", "BPC"), &bpc);
    Vec decode;
    dict_numbers(d, abbrev(d, "Decode", "D"), decode);
    CGPDFDataFormat format = CGPDFDataFormatRaw;
    std::vector<uint8_t> data = stream_bytes(s, &format);
    CGPDFObjectRef cso = NULL;
    CGPDFDictionaryGetObject(d, abbrev(d, "ColorSpace", "CS"), &cso);
    CSRef cs;
    if (!mask) {
        if (cso) {
            /* inline images name spaces in the resources too */
            cs = parse_space(cso, in.resources.empty() ? NULL : in.resources.back(), 0);
        }
        if (as_smask && !cs)
            cs = device_space("DeviceGray");
    }
    CGImageRef im = NULL;
    if (format == CGPDFDataFormatJPEGEncoded) {
        CFDataRef jd = CFDataCreate(NULL, data.data(), (CFIndex)data.size());
        CGDataProviderRef p = CGDataProviderCreateWithCFData(jd);
        CFRelease(jd);
        CGFloat dec[8];
        bool use_decode = decode.size() >= 2 && decode.size() <= 8 && decode[0] == 1 && decode[1] == 0;
        for (size_t i = 0; use_decode && i < decode.size(); i++)
            dec[i] = decode[i];
        im = CGImageCreateWithJPEGDataProvider(p, use_decode ? dec : NULL, interp, kCGRenderingIntentDefault);
        CGDataProviderRelease(p);
        if (im && (as_smask || (cs && cs->n == 1 && cs->kind != ColorSpace::Indexed))) {
            /* a gray JPEG (soft masks are) as 8-bit gray samples, which masks need */
            CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
            size_t iw = CGImageGetWidth(im), ih = CGImageGetHeight(im);
            CGContextRef gc = CGBitmapContextCreate(NULL, iw, ih, 8, 0, gray, kCGImageAlphaNone);
            CGColorSpaceRelease(gray);
            if (gc) {
                CGContextSetInterpolationQuality(gc, kCGInterpolationNone);
                CGContextSetBlendMode(gc, kCGBlendModeCopy);
                CGContextDrawImage(gc, CGRectMake(0, 0, iw, ih), im);
                CGImageRelease(im);
                im = CGBitmapContextCreateImage(gc);
                CGContextRelease(gc);
            }
            if (as_smask || !im)
                return im;
        }
        if (im && cs && cs->kind != ColorSpace::Indexed && cs->cg &&
            CGColorSpaceGetNumberOfComponents(cs->cg) == CGColorSpaceGetNumberOfComponents(CGImageGetColorSpace(im)) &&
            cs->kind != ColorSpace::Separation && cs->kind != ColorSpace::DeviceN) {
            CGImageRef copy = CGImageCreateCopyWithColorSpace(im, cs->cg);
            if (copy) {
                CGImageRelease(im);
                im = copy;
            }
        }
    } else if (format == CGPDFDataFormatJPEG2000) {
        return NULL;  /* JPEG 2000 isn't decoded */
    } else if (mask) {
        size_t bpr = ((size_t)w + 7) / 8;
        data.resize(bpr * (size_t)h, 0);
        CFDataRef md = CFDataCreate(NULL, data.data(), (CFIndex)data.size());
        CGDataProviderRef p = CGDataProviderCreateWithCFData(md);
        CFRelease(md);
        CGFloat dec[2] = {0, 1};
        if (decode.size() == 2)
            dec[0] = decode[0], dec[1] = decode[1];
        if (as_smask) {
            /* a stencil used as a soft mask: 1 where it paints */
            CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray();
            CGFloat inv[2] = {dec[1], dec[0]};
            im = CGImageCreate((size_t)w, (size_t)h, 1, 1, bpr, gray, kCGImageAlphaNone, p, inv, interp,
                               kCGRenderingIntentDefault);
            CGColorSpaceRelease(gray);
        } else {
            im = CGImageMaskCreate((size_t)w, (size_t)h, 1, 1, bpr, p, dec, interp);
        }
        CGDataProviderRelease(p);
        return im;
    } else {
        if (!cs || !cs->cg || cs->kind == ColorSpace::Pattern)
            return NULL;
        if (bpc != 1 && bpc != 2 && bpc != 4 && bpc != 8 && bpc != 16)
            return NULL;
        size_t n = (size_t)cs->n;
        size_t bpr = ((size_t)w * n * (size_t)bpc + 7) / 8;
        data.resize(bpr * (size_t)h, 0);
        CGColorSpaceRef target = NULL;
        std::vector<uint8_t> pixels;
        size_t out_bpc = (size_t)bpc, out_bpr = bpr;
        Vec dec = decode;
        if (cs->kind == ColorSpace::Separation || cs->kind == ColorSpace::DeviceN ||
            (cs->kind == ColorSpace::Indexed &&
             (cs->base->kind == ColorSpace::Separation || cs->base->kind == ColorSpace::DeviceN))) {
            /* converted to the alternate space, sample by sample */
            size_t on = cs->cg_components();
            out_bpc = 8, out_bpr = (size_t)w * on;
            pixels.resize(out_bpr * (size_t)h);
            uint32_t maxv = (1u << bpc) - 1;
            for (size_t y = 0; y < (size_t)h; y++)
                for (size_t x = 0; x < (size_t)w; x++) {
                    double in[32];
                    for (size_t k = 0; k < n; k++) {
                        size_t bit = (x * n + k) * (size_t)bpc;
                        uint32_t v = 0;
                        for (int b = 0; b < bpc; b++, bit++)
                            v = v << 1 | ((data[y * bpr + bit / 8] >> (7 - bit % 8)) & 1);
                        double d0 = dec.size() > 2 * k + 1 ? dec[2 * k] : 0;
                        double d1 = dec.size() > 2 * k + 1 ? dec[2 * k + 1] : cs->kind == ColorSpace::Indexed ? maxv : 1;
                        in[k] = d0 + v * (d1 - d0) / maxv;
                    }
                    CGFloat out[32];
                    cs->convert(in, out);
                    for (size_t k = 0; k < on; k++)
                        pixels[y * out_bpr + x * on + k] = (uint8_t)lround(fmin(1, fmax(0, out[k])) * 255);
                }
            target = (CGColorSpaceRef)CFRetain(cs->cg);
            dec.clear();
            n = on;
        } else if (cs->kind == ColorSpace::Indexed) {
            std::vector<uint8_t> table((size_t)(cs->hival + 1) * (size_t)cs->base->n, 0);
            for (size_t i = 0; i < table.size() && i < cs->lookup.size(); i++)
                table[i] = cs->lookup[i];
            target = CGColorSpaceCreateIndexed(cs->base->cg, (size_t)cs->hival, table.data());
            pixels = data;
        } else {
            target = (CGColorSpaceRef)CFRetain(cs->cg);
            pixels = data;
        }
        if (!target)
            return NULL;
        CFDataRef pd = CFDataCreate(NULL, pixels.data(), (CFIndex)pixels.size());
        CGDataProviderRef p = CGDataProviderCreateWithCFData(pd);
        CFRelease(pd);
        std::vector<CGFloat> cdec(dec.begin(), dec.end());
        if (cs->kind == ColorSpace::Lab && cdec.empty() && cs->range.size() == 4)
            cdec = {0, 100, cs->range[0], cs->range[1], cs->range[2], cs->range[3]};
        if (cdec.size() != 2 * n)
            cdec.clear();
        im = CGImageCreate((size_t)w, (size_t)h, out_bpc, out_bpc * n, out_bpr, target, kCGImageAlphaNone, p,
                           cdec.empty() ? NULL : cdec.data(), interp, kCGRenderingIntentDefault);
        CGDataProviderRelease(p);
        CGColorSpaceRelease(target);
    }
    if (!im || as_smask)
        return im;
    /* masks: a soft mask, a stencil, or colour-key ranges */
    CGPDFStreamRef ms;
    CGPDFArrayRef ma;
    if (!inl && CGPDFDictionaryGetStream(d, "SMask", &ms)) {
        bool dummy;
        CGImageRef smask = image_from_stream(in, ms, false, &dummy, true);
        if (smask) {
            CGImageRef masked = CGImageCreateWithMask(im, smask);
            CGImageRelease(smask);
            if (masked) {
                CGImageRelease(im);
                im = masked;
            }
        }
    } else if (!inl && CGPDFDictionaryGetStream(d, "Mask", &ms)) {
        bool m2;
        CGImageRef stencil = image_from_stream(in, ms, false, &m2);
        if (stencil) {
            CGImageRef masked = CGImageCreateWithMask(im, stencil);
            CGImageRelease(stencil);
            if (masked) {
                CGImageRelease(im);
                im = masked;
            }
        }
    } else if (CGPDFDictionaryGetArray(d, "Mask", &ma)) {
        Vec r;
        if (numbers(ma, r) && cs && r.size() == 2 * (size_t)cs->n && cs->kind != ColorSpace::Separation &&
            cs->kind != ColorSpace::DeviceN) {
            std::vector<CGFloat> comps(r.begin(), r.end());
            CGImageRef masked = CGImageCreateWithMaskingColors(im, comps.data());
            if (masked) {
                CGImageRelease(im);
                im = masked;
            }
        }
    }
    return im;
}

static void
draw_image(Interp &in, CGPDFStreamRef s, bool inl)
{
    bool is_mask = false;
    CGImageRef im = image_from_stream(in, s, inl, &is_mask);
    if (!im)
        return;
    CGContextRef c = in.c;
    State &st = in.st();
    if (is_mask && st.fill_cs && st.fill_cs->kind == ColorSpace::Pattern && !in.uncolored) {
        /* a stencil painted with a pattern: clip to the stencil, then fill */
        CGContextSaveGState(c);
        CGContextClipToMask(c, CGRectMake(0, 0, 1, 1), im);
        CGPathRef unit = CGPathCreateWithRect(CGRectMake(0, 0, 1, 1), NULL);
        run_pattern_fill(in, st.fill_pattern, false, unit, false);
        CGPathRelease(unit);
        CGContextRestoreGState(c);
    } else {
        CGContextSaveGState(c);
        if (!is_mask)
            CGContextSetAlpha(c, st.fill_alpha);
        CGContextDrawImage(c, CGRectMake(0, 0, 1, 1), im);
        CGContextRestoreGState(c);
    }
    CGImageRelease(im);
}

#pragma mark - Forms, groups and soft masks (sections 8.10, 11.6)

static void
run_stream(Interp &in, CGPDFStreamRef s, CGPDFDictionaryRef resources)
{
    if (in.depth > 24)
        return;
    std::vector<uint8_t> bytes = stream_bytes(s);
    in.depth++;
    in.resources.push_back(resources ? resources : in.resources.empty() ? NULL : in.resources.back());
    run_content(in, bytes.data(), bytes.size());
    in.resources.pop_back();
    in.depth--;
}

/* Run a stream with its own graphics-state stack level, restoring whatever it left unbalanced. */
static void
run_isolated(Interp &in, CGPDFStreamRef s, CGPDFDictionaryRef resources)
{
    size_t levels = in.stack.size();
    int saves = in.saves;
    run_stream(in, s, resources);
    while (in.saves > saves) {
        CGContextRestoreGState(in.c);
        in.saves--;
    }
    in.stack.resize(levels);
}

static void
do_form(Interp &in, CGPDFStreamRef s, bool group_ok = true)
{
    CGPDFDictionaryRef d = CGPDFStreamGetDictionary(s);
    CGContextRef c = in.c;
    CGContextSaveGState(c);
    in.stack.push_back(State(in.st()));
    CGContextConcatCTM(c, matrix_of(d, "Matrix"));
    Vec bbox;
    if (dict_numbers(d, "BBox", bbox) && bbox.size() == 4)
        CGContextClipToRect(c, CGRectStandardize(CGRectMake(bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1])));
    CGPDFDictionaryRef group = NULL, res = NULL;
    CGPDFDictionaryGetDictionary(d, "Resources", &res);
    const char *gs = NULL;
    bool transparency = group_ok && CGPDFDictionaryGetDictionary(d, "Group", &group) &&
                        CGPDFDictionaryGetName(group, "S", &gs) && !strcmp(gs, "Transparency");
    State &st = in.st();
    if (transparency) {
        /* the group composites as one object with the current alpha and blend mode; inside, they start over */
        CGContextSetAlpha(c, st.fill_alpha);
        CGContextSetBlendMode(c, st.blend);
        CGContextBeginTransparencyLayer(c, NULL);
        CGContextSetAlpha(c, 1);
        CGContextSetBlendMode(c, kCGBlendModeNormal);
        st.fill_alpha = st.stroke_alpha = 1;
        st.blend = kCGBlendModeNormal;
        apply_colors(in);
    }
    in.pattern_base.push_back(CGContextGetCTM(c));
    run_isolated(in, s, res);
    in.pattern_base.pop_back();
    if (transparency)
        CGContextEndTransparencyLayer(c);
    in.stack.pop_back();
    CGContextRestoreGState(c);
    apply_colors(in);
}

/*
 * A soft mask (section 11.6.5.2): the group drawn into a gray bitmap over
 * the area it can cover, luminosity or alpha becoming coverage, then used
 * to clip what follows.
 */
static void
apply_soft_mask(Interp &in, CGPDFDictionaryRef sm)
{
    CGContextRef c = in.c;
    const char *subtype = "Luminosity";
    CGPDFDictionaryGetName(sm, "S", &subtype);
    CGPDFStreamRef g;
    if (!CGPDFDictionaryGetStream(sm, "G", &g))
        return;
    CGPDFDictionaryRef gd = CGPDFStreamGetDictionary(g);
    Vec bbox;
    if (!dict_numbers(gd, "BBox", bbox) || bbox.size() != 4)
        return;
    /* the mask's extent in the current user space, and its size in device pixels */
    CGAffineTransform fm = matrix_of(gd, "Matrix");
    CGRect area = CGRectApplyAffineTransform(
        CGRectStandardize(CGRectMake(bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1])), fm);
    area = CGRectIntersection(area, CGContextGetClipBoundingBox(c));
    if (CGRectIsNull(area) || CGRectIsEmpty(area))
        return;
    CGRect dev = CGContextConvertRectToDeviceSpace(c, area);
    double scale = fmax(1, fmin(4096 / fmax(dev.size.width, dev.size.height), 1));
    size_t pw = (size_t)ceil(fabs(dev.size.width) * scale) + 2, ph = (size_t)ceil(fabs(dev.size.height) * scale) + 2;
    if (pw * ph > 16 * 1024 * 1024)
        return;
    pw = std::max<size_t>(pw, 1), ph = std::max<size_t>(ph, 1);
    bool luminosity = strcmp(subtype, "Alpha") != 0;
    CGColorSpaceRef gray = CGColorSpaceCreateDeviceGray(), rgb = CGColorSpaceCreateDeviceRGB();
    CGContextRef mc = CGBitmapContextCreate(NULL, pw, ph, 8, 0, rgb, kCGImageAlphaPremultipliedLast);
    if (!mc) {
        CGColorSpaceRelease(gray), CGColorSpaceRelease(rgb);
        return;
    }
    /* backdrop: the BC colour (black by default) for luminosity, transparent for alpha */
    if (luminosity) {
        Vec bc;
        dict_numbers(sm, "BC", bc);
        double v = 0;
        if (bc.size() == 1)
            v = bc[0];
        else if (bc.size() == 3)
            v = 0.3 * bc[0] + 0.59 * bc[1] + 0.11 * bc[2];
        else if (bc.size() == 4)
            v = 1 - fmin(1, 0.3 * bc[0] + 0.59 * bc[1] + 0.11 * bc[2] + bc[3]);
        CGContextSetRGBFillColor(mc, v, v, v, 1);
        CGContextFillRect(mc, CGRectMake(0, 0, pw, ph));
    }
    /* the mask's pixels cover `area`, from (1, 1) */
    CGContextTranslateCTM(mc, 1, 1);
    CGContextScaleCTM(mc, (pw - 2) / area.size.width, (ph - 2) / area.size.height);
    CGContextTranslateCTM(mc, -area.origin.x, -area.origin.y);
    Interp sub = in;
    sub.c = mc;
    sub.stack.assign(1, State());
    sub.st().fill_cs = sub.st().stroke_cs = device_space("DeviceGray");
    sub.st().fill = sub.st().stroke = {0};
    sub.pattern_base.assign(1, CGContextGetCTM(mc));
    sub.text_clip = NULL;
    sub.saves = 0;
    apply_colors(sub);
    do_form(sub, g, false);
    /* coverage from the mask's pixels */
    const uint8_t *px = (const uint8_t *)CGBitmapContextGetData(mc);
    size_t bpr = CGBitmapContextGetBytesPerRow(mc);
    std::vector<uint8_t> cov(pw * ph);
    CGPDFObjectRef tr = NULL;
    FunctionSet transfer;
    if (CGPDFDictionaryGetObject(sm, "TR", &tr))
        transfer = parse_functions(tr);
    for (size_t y = 0; y < ph; y++)
        for (size_t x = 0; x < pw; x++) {
            const uint8_t *p = px + y * bpr + 4 * x;
            double v = luminosity ? (0.3 * p[0] + 0.59 * p[1] + 0.11 * p[2]) / 255 : p[3] / 255.0;
            if (!transfer.empty()) {
                double o = v;
                transfer.eval(&v, &o);
                v = o;
            }
            cov[y * pw + x] = (uint8_t)lround(fmin(1, fmax(0, v)) * 255);
        }
    CGContextRelease(mc);
    CFDataRef cd = CFDataCreate(NULL, cov.data(), (CFIndex)cov.size());
    CGDataProviderRef p = CGDataProviderCreateWithCFData(cd);
    CFRelease(cd);
    CGImageRef mask = CGImageCreate(pw, ph, 8, 8, pw, gray, kCGImageAlphaNone, p, NULL, true, kCGRenderingIntentDefault);
    CGDataProviderRelease(p);
    CGColorSpaceRelease(gray), CGColorSpaceRelease(rgb);
    if (mask) {
        /* the bitmap's border pixel is outside `area` */
        double sx = area.size.width / (pw - 2), sy = area.size.height / (ph - 2);
        CGContextClipToMask(c, CGRectMake(area.origin.x - sx, area.origin.y - sy, pw * sx, ph * sy), mask);
        CGImageRelease(mask);
    }
}

static CGBlendMode
blend_mode(const char *n)
{
    static const struct {
        const char *name;
        CGBlendMode mode;
    } modes[] = {
        {"Normal", kCGBlendModeNormal}, {"Compatible", kCGBlendModeNormal}, {"Multiply", kCGBlendModeMultiply},
        {"Screen", kCGBlendModeScreen}, {"Overlay", kCGBlendModeOverlay}, {"Darken", kCGBlendModeDarken},
        {"Lighten", kCGBlendModeLighten}, {"ColorDodge", kCGBlendModeColorDodge}, {"ColorBurn", kCGBlendModeColorBurn},
        {"HardLight", kCGBlendModeHardLight}, {"SoftLight", kCGBlendModeSoftLight},
        {"Difference", kCGBlendModeDifference}, {"Exclusion", kCGBlendModeExclusion}, {"Hue", kCGBlendModeHue},
        {"Saturation", kCGBlendModeSaturation}, {"Color", kCGBlendModeColor}, {"Luminosity", kCGBlendModeLuminosity},
    };
    for (auto &m : modes)
        if (!strcmp(m.name, n))
            return m.mode;
    return kCGBlendModeNormal;
}

static Font *font_for(Interp &in, CGPDFDictionaryRef fd);

static void
ext_gstate(Interp &in, const char *name)
{
    CGPDFDictionaryRef gs = object_dict(in.resource("ExtGState", name));
    if (!gs)
        return;
    CGContextRef c = in.c;
    State &s = in.st();
    CGPDFReal v;
    CGPDFInteger iv;
    if (CGPDFDictionaryGetNumber(gs, "LW", &v))
        CGContextSetLineWidth(c, v), s.line_width = v;
    if (CGPDFDictionaryGetInteger(gs, "LC", &iv))
        CGContextSetLineCap(c, (CGLineCap)iv);
    if (CGPDFDictionaryGetInteger(gs, "LJ", &iv))
        CGContextSetLineJoin(c, (CGLineJoin)iv);
    if (CGPDFDictionaryGetNumber(gs, "ML", &v))
        CGContextSetMiterLimit(c, v);
    if (CGPDFDictionaryGetNumber(gs, "FL", &v))
        CGContextSetFlatness(c, v);
    CGPDFArrayRef dash;
    if (CGPDFDictionaryGetArray(gs, "D", &dash)) {
        CGPDFArrayRef lengths;
        CGPDFReal phase = 0;
        Vec l;
        if (CGPDFArrayGetArray(dash, 0, &lengths) && numbers(lengths, l)) {
            CGPDFArrayGetNumber(dash, 1, &phase);
            std::vector<CGFloat> cl(l.begin(), l.end());
            CGContextSetLineDash(c, phase, cl.empty() ? NULL : cl.data(), cl.size());
        }
    }
    bool colors = false;
    if (CGPDFDictionaryGetNumber(gs, "CA", &v))
        s.stroke_alpha = fmin(1, fmax(0, v)), colors = true;
    if (CGPDFDictionaryGetNumber(gs, "ca", &v))
        s.fill_alpha = fmin(1, fmax(0, v)), colors = true;
    const char *bm;
    CGPDFArrayRef bma;
    if (CGPDFDictionaryGetName(gs, "BM", &bm) ||
        (CGPDFDictionaryGetArray(gs, "BM", &bma) && CGPDFArrayGetName(bma, 0, &bm))) {
        s.blend = blend_mode(bm);
        CGContextSetBlendMode(c, s.blend);
    }
    CGPDFArrayRef font;
    CGPDFDictionaryRef fd;
    if (CGPDFDictionaryGetArray(gs, "Font", &font) && CGPDFArrayGetDictionary(font, 0, &fd)) {
        s.font = font_for(in, fd);
        CGPDFReal size = 0;
        CGPDFArrayGetNumber(font, 1, &size);
        s.Tfs = size;
    }
    CGPDFDictionaryRef sm;
    if (CGPDFDictionaryGetDictionary(gs, "SMask", &sm))
        apply_soft_mask(in, sm);
    if (colors)
        apply_colors(in);
}

#pragma mark - Shadings and patterns (sections 8.7.3, 8.7.4)

struct ShadingInfo {
    FunctionSet fn;
    CSRef cs;
    double t0, t1;
};

static void
shading_eval(void *info, const CGFloat *in, CGFloat *out)
{
    ShadingInfo *si = (ShadingInfo *)info;
    double t = si->t0 + in[0] * (si->t1 - si->t0), v[32] = {0};
    si->fn.eval(&t, v);
    si->cs->convert(v, out);
}

static void
shading_release(void *info)
{
    delete (ShadingInfo *)info;
}

/* A colour from a shading's colour space and function, for the subdividing shadings. */
static CGColorRef
shading_color(const ShadingInfo &si, const double *v, size_t nv, double alpha)
{
    double comps[32] = {0};
    if (!si.fn.empty()) {
        si.fn.eval(v, comps);
    } else {
        for (size_t i = 0; i < nv && i < 32; i++)
            comps[i] = v[i];
    }
    CGFloat out[CG_COLOR_MAX_COMPONENTS] = {0};
    si.cs->convert(comps, out);
    out[si.cs->cg_components()] = alpha;
    return CGColorCreate(si.cs->cg, out);
}

static void
fill_poly(CGContextRef c, const CGPoint *p, size_t n, CGColorRef col)
{
    CGContextSetFillColorWithColor(c, col);
    CGContextBeginPath(c);
    CGContextAddLines(c, p, n);
    CGContextClosePath(c);
    CGContextFillPath(c);
}

struct MeshVertex {
    CGPoint p;
    double v[32];
};

/* Gouraud triangles by subdivision into flat pieces. */
static void
fill_triangle(CGContextRef c, const ShadingInfo &si, size_t nv, const MeshVertex &a, const MeshVertex &b,
              const MeshVertex &d, double alpha, int depth)
{
    CGAffineTransform t = CGContextGetUserSpaceToDeviceSpaceTransform(c);
    CGPoint pa = CGPointApplyAffineTransform(a.p, t), pb = CGPointApplyAffineTransform(b.p, t),
            pd = CGPointApplyAffineTransform(d.p, t);
    double span = fmax(fmax(hypot(pa.x - pb.x, pa.y - pb.y), hypot(pb.x - pd.x, pb.y - pd.y)), hypot(pa.x - pd.x, pa.y - pd.y));
    double cdiff = 0;
    for (size_t k = 0; k < nv; k++)
        cdiff = fmax(cdiff, fmax(fabs(a.v[k] - b.v[k]), fmax(fabs(b.v[k] - d.v[k]), fabs(a.v[k] - d.v[k]))));
    if (depth >= 7 || span < 2 || cdiff < 0.004) {
        MeshVertex m;
        for (size_t k = 0; k < nv; k++)
            m.v[k] = (a.v[k] + b.v[k] + d.v[k]) / 3;
        CGColorRef col = shading_color(si, m.v, nv, alpha);
        CGPoint pts[3] = {a.p, b.p, d.p};
        fill_poly(c, pts, 3, col);
        CGColorRelease(col);
        return;
    }
    auto mid = [&](const MeshVertex &x, const MeshVertex &y) {
        MeshVertex m;
        m.p = CGPointMake((x.p.x + y.p.x) / 2, (x.p.y + y.p.y) / 2);
        for (size_t k = 0; k < nv; k++)
            m.v[k] = (x.v[k] + y.v[k]) / 2;
        return m;
    };
    MeshVertex ab = mid(a, b), bd = mid(b, d), ad = mid(a, d);
    fill_triangle(c, si, nv, a, ab, ad, alpha, depth + 1);
    fill_triangle(c, si, nv, ab, b, bd, alpha, depth + 1);
    fill_triangle(c, si, nv, ad, bd, d, alpha, depth + 1);
    fill_triangle(c, si, nv, ab, bd, ad, alpha, depth + 1);
}

/* Reads the packed fields of a mesh shading's stream. */
struct BitReader {
    const std::vector<uint8_t> &d;
    size_t bit = 0;
    explicit BitReader(const std::vector<uint8_t> &data) : d(data) {}
    bool more(int bits) const { return bit + (size_t)bits <= d.size() * 8; }
    uint64_t get(int bits)
    {
        uint64_t v = 0;
        for (int i = 0; i < bits; i++, bit++)
            v = v << 1 | (uint64_t)((d[bit / 8] >> (7 - bit % 8)) & 1);
        return v;
    }
    void align() { bit = (bit + 7) & ~(size_t)7; }
};

static void
mesh_shading(Interp &in, CGPDFStreamRef s, int type, const ShadingInfo &si, double alpha)
{
    CGPDFDictionaryRef d = CGPDFStreamGetDictionary(s);
    CGPDFInteger bpc = 8, bpcomp = 8, bpf = 8, per_row = 2;
    CGPDFDictionaryGetInteger(d, "BitsPerCoordinate", &bpc);
    CGPDFDictionaryGetInteger(d, "BitsPerComponent", &bpcomp);
    CGPDFDictionaryGetInteger(d, "BitsPerFlag", &bpf);
    CGPDFDictionaryGetInteger(d, "VerticesPerRow", &per_row);
    Vec dec;
    if (!dict_numbers(d, "Decode", dec) || dec.size() < 6 || bpc < 1 || bpc > 32 || bpcomp < 1 || bpcomp > 16)
        return;
    size_t nv = si.fn.empty() ? (size_t)si.cs->n : 1;
    if (dec.size() < 4 + 2 * nv)
        return;
    std::vector<uint8_t> data = stream_bytes(s);
    BitReader r(data);
    double cmax = pow(2, (double)bpc) - 1, vmax = pow(2, (double)bpcomp) - 1;
    auto vertex = [&](MeshVertex &m) {
        m.p.x = dec[0] + r.get((int)bpc) * (dec[1] - dec[0]) / cmax;
        m.p.y = dec[2] + r.get((int)bpc) * (dec[3] - dec[2]) / cmax;
        for (size_t k = 0; k < nv; k++)
            m.v[k] = dec[4 + 2 * k] + r.get((int)bpcomp) * (dec[5 + 2 * k] - dec[4 + 2 * k]) / vmax;
    };
    size_t vbits = (size_t)(2 * bpc + (CGPDFInteger)nv * bpcomp);
    CGContextRef c = in.c;
    if (type == 4) {
        MeshVertex tri[3];
        int have = 0;
        while (r.more((int)(bpf + (CGPDFInteger)vbits))) {
            int flag = (int)r.get((int)bpf);
            MeshVertex m;
            vertex(m);
            r.align();
            if (flag == 0 || have < 3) {
                if (flag == 0 && have >= 3)
                    have = 0;
                tri[have < 3 ? have : 2] = m;
                have++;
            } else if (flag == 1) {
                tri[0] = tri[1], tri[1] = tri[2], tri[2] = m;
            } else {
                tri[1] = tri[2], tri[2] = m;
            }
            if (have >= 3) {
                fill_triangle(c, si, nv, tri[0], tri[1], tri[2], alpha, 0);
                if (flag == 0 && have == 3)
                    have = 3;
            }
        }
    } else if (type == 5) {
        std::vector<MeshVertex> prev, row;
        while (r.more((int)vbits)) {
            row.clear();
            for (CGPDFInteger i = 0; i < per_row && r.more((int)vbits); i++) {
                MeshVertex m;
                vertex(m);
                row.push_back(m);
            }
            r.align();
            if (!prev.empty())
                for (size_t i = 0; i + 1 < row.size() && i + 1 < prev.size(); i++) {
                    fill_triangle(c, si, nv, prev[i], prev[i + 1], row[i], alpha, 0);
                    fill_triangle(c, si, nv, prev[i + 1], row[i + 1], row[i], alpha, 0);
                }
            prev = row;
        }
    } else {
        /* Coons (6) and tensor-product (7) patches: evaluated on a grid as bicubic Coons patches */
        int npts = type == 6 ? 12 : 16;
        CGPoint pts[16], prevp[16];
        double cols[4][32], prevc[4][32];
        bool have_prev = false;
        while (r.more((int)bpf)) {
            int flag = (int)r.get((int)bpf);
            int newp = flag == 0 ? npts : npts - 4, newc = flag == 0 ? 4 : 2;
            if (!r.more((int)(newp * 2 * bpc + newc * (CGPDFInteger)nv * bpcomp)))
                break;
            CGPoint pp[16];
            double cc[4][32];
            for (int i = 0; i < newp; i++) {
                pp[i].x = dec[0] + r.get((int)bpc) * (dec[1] - dec[0]) / cmax;
                pp[i].y = dec[2] + r.get((int)bpc) * (dec[3] - dec[2]) / cmax;
            }
            for (int i = 0; i < newc; i++)
                for (size_t k = 0; k < nv; k++)
                    cc[i][k] = dec[4 + 2 * k] + r.get((int)bpcomp) * (dec[5 + 2 * k] - dec[4 + 2 * k]) / vmax;
            r.align();
            if (flag == 0) {
                memcpy(pts, pp, sizeof(CGPoint) * (size_t)npts);
                memcpy(cols, cc, sizeof cols);
            } else {
                if (!have_prev)
                    break;
                /* the shared edge of the previous patch (in boundary order: 12 points around) */
                static const int edge[4][4] = {{0, 0, 0, 0}, {3, 4, 5, 6}, {6, 7, 8, 9}, {9, 10, 11, 0}};
                static const int cedge[4][2] = {{0, 0}, {1, 2}, {2, 3}, {3, 0}};
                for (int i = 0; i < 4; i++)
                    pts[i] = prevp[edge[flag][i]];
                for (int i = 0; i < newp; i++)
                    pts[4 + i] = pp[i];
                for (size_t k = 0; k < nv; k++) {
                    cols[0][k] = prevc[cedge[flag][0]][k];
                    cols[1][k] = prevc[cedge[flag][1]][k];
                    cols[2][k] = cc[0][k];
                    cols[3][k] = cc[1][k];
                }
            }
            memcpy(prevp, pts, sizeof prevp);
            memcpy(prevc, cols, sizeof prevc);
            have_prev = true;
            /* boundary curves: C1 (bottom, u) = p0..p3, D2 (right, v) = p3..p6, C2 (top) = p9..p6, D1 (left) = p0..p11..p9 */
            auto bez = [](CGPoint a, CGPoint b, CGPoint c2, CGPoint d2, double t) {
                double u = 1 - t;
                return CGPointMake(u * u * u * a.x + 3 * u * u * t * b.x + 3 * u * t * t * c2.x + t * t * t * d2.x,
                                   u * u * u * a.y + 3 * u * u * t * b.y + 3 * u * t * t * c2.y + t * t * t * d2.y);
            };
            const int G = 12;
            CGPoint grid[G + 1][G + 1];
            for (int i = 0; i <= G; i++)
                for (int j = 0; j <= G; j++) {
                    double u = (double)i / G, v = (double)j / G;
                    CGPoint c1 = bez(pts[0], pts[1], pts[2], pts[3], u), c2 = bez(pts[9], pts[8], pts[7], pts[6], u);
                    CGPoint d1 = bez(pts[0], pts[11], pts[10], pts[9], v), d2 = bez(pts[3], pts[4], pts[5], pts[6], v);
                    double x = (1 - v) * c1.x + v * c2.x + (1 - u) * d1.x + u * d2.x -
                               ((1 - u) * (1 - v) * pts[0].x + u * (1 - v) * pts[3].x + (1 - u) * v * pts[9].x + u * v * pts[6].x);
                    double y = (1 - v) * c1.y + v * c2.y + (1 - u) * d1.y + u * d2.y -
                               ((1 - u) * (1 - v) * pts[0].y + u * (1 - v) * pts[3].y + (1 - u) * v * pts[9].y + u * v * pts[6].y);
                    grid[i][j] = CGPointMake(x, y);
                }
            for (int i = 0; i < G; i++)
                for (int j = 0; j < G; j++) {
                    double u = (i + 0.5) / G, v = (j + 0.5) / G, val[32];
                    for (size_t k = 0; k < nv; k++)
                        val[k] = (1 - u) * (1 - v) * cols[0][k] + u * (1 - v) * cols[1][k] + u * v * cols[2][k] +
                                 (1 - u) * v * cols[3][k];
                    CGColorRef col = shading_color(si, val, nv, alpha);
                    CGPoint q[4] = {grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]};
                    fill_poly(c, q, 4, col);
                    CGColorRelease(col);
                }
        }
    }
}

/* Draw a shading over the current clip (for "sh" and shading patterns). */
static void
draw_shading(Interp &in, CGPDFDictionaryRef sh, bool as_pattern)
{
    CGPDFInteger type = 0;
    CGPDFObjectRef cso, fo = NULL;
    if (!sh || !CGPDFDictionaryGetInteger(sh, "ShadingType", &type) || !CGPDFDictionaryGetObject(sh, "ColorSpace", &cso))
        return;
    CSRef cs = parse_space(cso, in.resources.empty() ? NULL : in.resources.back(), 0);
    if (!cs || !cs->cg || cs->kind == ColorSpace::Pattern)
        return;
    CGContextRef c = in.c;
    State &st = in.st();
    double alpha = st.fill_alpha;
    auto si = new ShadingInfo();
    si->cs = cs;
    if (CGPDFDictionaryGetObject(sh, "Function", &fo))
        si->fn = parse_functions(fo);
    Vec domain;
    if (!dict_numbers(sh, "Domain", domain) || domain.size() < 2)
        domain = {0, 1};
    si->t0 = domain[0], si->t1 = domain[1];
    CGContextSaveGState(c);
    Vec bbox;
    if (dict_numbers(sh, "BBox", bbox) && bbox.size() == 4)
        CGContextClipToRect(c, CGRectStandardize(CGRectMake(bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1])));
    if (type == 2 || type == 3) {
        Vec coords, extend;
        CGPDFArrayRef ea;
        bool e0 = false, e1 = false;
        if (CGPDFDictionaryGetArray(sh, "Extend", &ea)) {
            CGPDFBoolean b0 = 0, b1 = 0;
            CGPDFArrayGetBoolean(ea, 0, &b0);
            CGPDFArrayGetBoolean(ea, 1, &b1);
            e0 = b0, e1 = b1;
        }
        size_t need = type == 2 ? 4 : 6;
        if (dict_numbers(sh, "Coords", coords) && coords.size() == need && !si->fn.empty()) {
            CGFloat d01[2] = {0, 1};
            size_t n = cs->cg_components();
            CGFunctionCallbacks cb = {0, shading_eval, shading_release};
            CGFunctionRef f = CGFunctionCreate(si, 1, d01, n, NULL, &cb);
            si = NULL;
            CGShadingRef shading =
                type == 2 ? CGShadingCreateAxial(cs->cg, CGPointMake(coords[0], coords[1]), CGPointMake(coords[2], coords[3]), f, e0, e1)
                          : CGShadingCreateRadial(cs->cg, CGPointMake(coords[0], coords[1]), coords[2],
                                                  CGPointMake(coords[3], coords[4]), coords[5], f, e0, e1);
            CGFunctionRelease(f);
            if (shading) {
                CGContextSetAlpha(c, alpha);
                CGContextDrawShading(c, shading);
                CGShadingRelease(shading);
            }
        }
    } else if (type == 1 && !si->fn.empty()) {
        /* function-based: sampled over its domain into an image, drawn through its matrix */
        Vec dom;
        if (!dict_numbers(sh, "Domain", dom) || dom.size() != 4)
            dom = {0, 1, 0, 1};
        CGContextConcatCTM(c, matrix_of(sh, "Matrix"));
        const size_t N = 128;
        size_t n = cs->cg_components();
        std::vector<uint8_t> px(N * N * n);
        for (size_t y = 0; y < N; y++)
            for (size_t x = 0; x < N; x++) {
                double in2[2] = {dom[0] + (x + 0.5) / N * (dom[1] - dom[0]), dom[3] - (y + 0.5) / N * (dom[3] - dom[2])};
                double v[32] = {0};
                si->fn.eval(in2, v);
                CGFloat out[32];
                cs->convert(v, out);
                for (size_t k = 0; k < n; k++)
                    px[(y * N + x) * n + k] = (uint8_t)lround(fmin(1, fmax(0, out[k])) * 255);
            }
        CFDataRef pd = CFDataCreate(NULL, px.data(), (CFIndex)px.size());
        CGDataProviderRef p = CGDataProviderCreateWithCFData(pd);
        CFRelease(pd);
        CGImageRef im = CGImageCreate(N, N, 8, 8 * n, N * n, cs->cg, kCGImageAlphaNone, p, NULL, true, kCGRenderingIntentDefault);
        CGDataProviderRelease(p);
        if (im) {
            CGContextSetAlpha(c, alpha);
            CGContextDrawImage(c, CGRectMake(dom[0], dom[2], dom[1] - dom[0], dom[3] - dom[2]), im);
            CGImageRelease(im);
        }
    }
    CGContextRestoreGState(c);
    if (si)
        delete si;
}

static void
draw_mesh(Interp &in, CGPDFStreamRef s)
{
    CGPDFDictionaryRef sh = CGPDFStreamGetDictionary(s);
    CGPDFInteger type = 0;
    CGPDFObjectRef cso, fo = NULL;
    if (!CGPDFDictionaryGetInteger(sh, "ShadingType", &type) || type < 4 || type > 7 ||
        !CGPDFDictionaryGetObject(sh, "ColorSpace", &cso))
        return;
    ShadingInfo si;
    si.cs = parse_space(cso, in.resources.empty() ? NULL : in.resources.back(), 0);
    if (!si.cs || !si.cs->cg || si.cs->kind == ColorSpace::Pattern)
        return;
    if (CGPDFDictionaryGetObject(sh, "Function", &fo))
        si.fn = parse_functions(fo);
    CGContextSaveGState(in.c);
    Vec bbox;
    if (dict_numbers(sh, "BBox", bbox) && bbox.size() == 4)
        CGContextClipToRect(in.c, CGRectStandardize(CGRectMake(bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1])));
    /* pieces drawn without antialiasing, so their shared edges don't show (Apple's are aliased too) */
    CGContextSetShouldAntialias(in.c, false);
    mesh_shading(in, s, (int)type, si, in.st().fill_alpha);
    CGContextRestoreGState(in.c);
}

static void
shading_object(Interp &in, CGPDFObjectRef o, bool as_pattern)
{
    CGPDFStreamRef s;
    CGPDFDictionaryRef d;
    if (CGPDFObjectGetValue(o, kCGPDFObjectTypeStream, &s)) {
        CGPDFInteger type = 0;
        CGPDFDictionaryGetInteger(CGPDFStreamGetDictionary(s), "ShadingType", &type);
        if (type >= 4)
            draw_mesh(in, s);
        else
            draw_shading(in, CGPDFStreamGetDictionary(s), as_pattern);
    } else if (CGPDFObjectGetValue(o, kCGPDFObjectTypeDictionary, &d)) {
        draw_shading(in, d, as_pattern);
    }
}

struct PatternInfo {
    Interp *in;
    CGPDFStreamRef stream;
    bool uncolored;
};

static void
pattern_draw(void *info, CGContextRef c)
{
    PatternInfo *pi = (PatternInfo *)info;
    Interp sub = *pi->in;
    sub.c = c;
    sub.stack.assign(1, State());
    sub.st().fill_cs = sub.st().stroke_cs = device_space("DeviceGray");
    sub.st().fill = sub.st().stroke = {0};
    sub.uncolored = pi->uncolored;
    sub.pattern_base.assign(1, CGContextGetCTM(c));
    sub.text_clip = NULL;
    sub.saves = 0;
    sub.pending_clip = 0;
    if (!sub.uncolored)
        apply_colors(sub);
    CGPDFDictionaryRef res = NULL;
    CGPDFDictionaryGetDictionary(CGPDFStreamGetDictionary(pi->stream), "Resources", &res);
    run_isolated(sub, pi->stream, res);
}

/* Fill (or stroke) `path` (user space) with a pattern colour. */
static void
run_pattern_fill(Interp &in, CGPDFObjectRef pattern, bool stroke, CGPathRef path, bool eo)
{
    CGContextRef c = in.c;
    CGPDFDictionaryRef pd = object_dict(pattern);
    CGPDFInteger type = 0;
    if (!pd || !CGPDFDictionaryGetInteger(pd, "PatternType", &type))
        return;
    State &st = in.st();
    CGAffineTransform base = in.pattern_base.empty() ? CGAffineTransformIdentity : in.pattern_base.back();
    CGAffineTransform pm = CGAffineTransformConcat(matrix_of(pd, "Matrix"), base);
    CGContextSaveGState(c);
    if (type == 2) {
        /* a shading pattern: clip to the shape, then the shading in pattern space */
        CGContextBeginPath(c);
        CGContextAddPath(c, path);
        if (stroke)
            CGContextReplacePathWithStrokedPath(c);
        if (eo)
            CGContextEOClip(c);
        else
            CGContextClip(c);
        CGAffineTransform ctm = CGContextGetCTM(c);
        CGContextConcatCTM(c, CGAffineTransformConcat(pm, CGAffineTransformInvert(ctm)));
        CGPDFObjectRef sho;
        CGPDFDictionaryRef gs;
        double alpha = st.fill_alpha;
        CGPDFReal a;
        if (CGPDFDictionaryGetDictionary(pd, "ExtGState", &gs) && CGPDFDictionaryGetNumber(gs, "ca", &a))
            in.st().fill_alpha = a;
        if (CGPDFDictionaryGetObject(pd, "Shading", &sho))
            shading_object(in, sho, true);
        in.st().fill_alpha = alpha;
        CGContextRestoreGState(c);
        return;
    }
    CGPDFStreamRef ps;
    if (type != 1 || !CGPDFObjectGetValue(pattern, kCGPDFObjectTypeStream, &ps)) {
        CGContextRestoreGState(c);
        return;
    }
    CGPDFInteger paint_type = 1;
    CGPDFDictionaryGetInteger(pd, "PaintType", &paint_type);
    Vec bbox;
    if (!dict_numbers(pd, "BBox", bbox) || bbox.size() != 4) {
        CGContextRestoreGState(c);
        return;
    }
    double xstep = dict_number(pd, "XStep", bbox[2] - bbox[0]), ystep = dict_number(pd, "YStep", bbox[3] - bbox[1]);
    PatternInfo *pi = new PatternInfo{&in, ps, paint_type == 2};
    CGPatternCallbacks cb = {0, pattern_draw, [](void *info) { delete (PatternInfo *)info; }};
    /* CG's pattern matrix maps the cell to the context's default user space, as `pm` does */
    CGAffineTransform to_default = pm;
    CGPatternRef pat = CGPatternCreate(pi, CGRectStandardize(CGRectMake(bbox[0], bbox[1], bbox[2] - bbox[0], bbox[3] - bbox[1])),
                                       to_default, fabs(xstep), fabs(ystep), kCGPatternTilingConstantSpacing,
                                       paint_type != 2, &cb);
    if (pat) {
        CSRef cs = stroke ? st.stroke_cs : st.fill_cs;
        const Vec &comps = stroke ? st.stroke : st.fill;
        double alpha = stroke ? st.stroke_alpha : st.fill_alpha;
        CGColorSpaceRef under = NULL;
        CGFloat v[CG_COLOR_MAX_COMPONENTS] = {0};
        if (paint_type == 2 && cs && cs->base && cs->base->cg) {
            double in2[32] = {0};
            for (size_t i = 0; i < comps.size() && i < 32; i++)
                in2[i] = comps[i];
            cs->base->convert(in2, v);
            v[cs->base->cg_components()] = alpha;
            under = cs->base->cg;
        } else {
            v[0] = alpha;
        }
        CGColorSpaceRef pspace = CGColorSpaceCreatePattern(under);
        if (stroke) {
            CGContextSetStrokeColorSpace(c, pspace);
            CGContextSetStrokePattern(c, pat, v);
        } else {
            CGContextSetFillColorSpace(c, pspace);
            CGContextSetFillPattern(c, pat, v);
        }
        CGColorSpaceRelease(pspace);
        CGContextBeginPath(c);
        CGContextAddPath(c, path);
        CGContextDrawPath(c, stroke ? kCGPathStroke : eo ? kCGPathEOFill : kCGPathFill);
        CGPatternRelease(pat);
    }
    CGContextRestoreGState(c);
}

#pragma mark - Text (section 9.4)

static Font *
font_for(Interp &in, CGPDFDictionaryRef fd)
{
    if (!fd)
        return NULL;
    auto it = in.fonts->find(fd);
    if (it != in.fonts->end())
        return it->second.get();
    auto f = load_font(fd);
    Font *p = f.get();
    (*in.fonts)[fd] = std::move(f);
    return p;
}

/* A glyph's outline in glyph space (font units scaled to 1 em), y up. */
static CGPathRef
glyph_outline(CGFontRef font, CGGlyph g)
{
    sk_sp<SkTypeface> tf = CGFontGetTypeface(font);
    if (!tf)
        return NULL;
    SkFont f(tf, 64);
    f.setHinting(SkFontHinting::kNone);
    std::optional<SkPath> p = f.getPath(g);
    if (!p || p->isEmpty())
        return NULL;
    CGMutablePathRef cp = CGPathFromSkPath(*p);
    CGAffineTransform t = CGAffineTransformMakeScale(1.0 / 64, -1.0 / 64);
    CGPathRef out = CGPathCreateCopyByTransformingPath(cp, &t);
    CFRelease(cp);
    return out;
}

static void
show_text(Interp &in, const uint8_t *s, size_t n)
{
    const State st = in.st();  /* a copy: Type 3 glyphs push states */
    Font *f = st.font;
    if (!f)
        return;
    CGContextRef c = in.c;
    int mode = st.Tr;
    bool clip = mode >= 4;
    bool draws = mode != 3 && mode != 7;
    double Th = st.Th;
    std::vector<CGGlyph> glyphs;
    std::vector<CGPoint> positions;
    CGAffineTransform start = in.Tm;
    double x = 0;
    for (size_t i = 0; i < n;) {
        int bytes;
        uint32_t code = f->next(s, n, i, bytes);
        double w0 = f->width(code);
        if (f->kind == Font::Type3) {
            /* the glyph's own content, through the font matrix */
            const char *name = code < 256 ? f->names[code] : NULL;
            CGPDFStreamRef proc;
            if (name && f->char_procs && CGPDFDictionaryGetStream(f->char_procs, name, &proc) && draws) {
                CGContextSaveGState(c);
                CGAffineTransform trm = CGAffineTransformMake(st.Tfs * Th, 0, 0, st.Tfs, 0, st.rise);
                trm = CGAffineTransformConcat(trm, in.Tm);
                CGContextConcatCTM(c, CGAffineTransformConcat(f->font_matrix, trm));
                in.stack.push_back(State(st));
                bool saved = in.uncolored;
                CGAffineTransform tm = in.Tm, tlm = in.Tlm;
                run_isolated(in, proc, f->resources ? f->resources : (in.resources.empty() ? NULL : in.resources.back()));
                in.Tm = tm, in.Tlm = tlm;
                in.uncolored = saved;
                in.stack.pop_back();
                CGContextRestoreGState(c);
                apply_colors(in);
            }
        } else {
            int g = f->glyph_of(code);
            if (g > 0 || f->kind == Font::Type0) {
                glyphs.push_back((CGGlyph)g);
                positions.push_back(CGPointMake(x / (Th ? Th : 1), 0));
            }
        }
        double tx = (w0 * st.Tfs + st.Tc + (bytes == 1 && code == 32 ? st.Tw : 0)) * Th;
        if (f->vertical && f->kind == Font::Type0)
            tx = 0;
        x += tx;
        in.Tm = CGAffineTransformConcat(CGAffineTransformMakeTranslation(tx, 0), in.Tm);
        if (f->kind == Font::Type3)
            start = in.Tm, x = 0;
    }
    if (glyphs.empty() || !f->cg || Th == 0)
        return;
    CGAffineTransform tm = CGAffineTransformConcat(CGAffineTransformMake(Th, 0, 0, 1, 0, st.rise), start);
    if (draws && !in.uncolored && ((st.fill_cs && st.fill_cs->kind == ColorSpace::Pattern && mode != 1 && mode != 5) ||
                                   (st.stroke_cs && st.stroke_cs->kind == ColorSpace::Pattern && mode != 0 && mode != 4))) {
        /* text in a pattern colour: as outlines */
        CGMutablePathRef p = CGPathCreateMutable();
        for (size_t i = 0; i < glyphs.size(); i++)
            if (CGPathRef g = glyph_outline(f->cg, glyphs[i])) {
                CGAffineTransform place = CGAffineTransformConcat(CGAffineTransformMakeScale(st.Tfs, st.Tfs),
                                                                  CGAffineTransformTranslate(tm, positions[i].x, 0));
                CGPathAddPath(p, &place, g);
                CFRelease(g);
            }
        CGContextBeginPath(c);
        CGContextAddPath(c, p);
        paint(in, mode == 1 || mode == 5 ? kCGPathStroke : mode == 2 || mode == 6 ? kCGPathFillStroke : kCGPathFill);
        CFRelease(p);
    } else if (draws) {
        CGContextSetFont(c, f->cg);
        CGContextSetFontSize(c, st.Tfs);
        CGContextSetTextMatrix(c, tm);
        CGContextSetCharacterSpacing(c, 0);
        static const CGTextDrawingMode modes[] = {kCGTextFill, kCGTextStroke, kCGTextFillStroke, kCGTextInvisible};
        CGContextSetTextDrawingMode(c, modes[mode & 3]);
        CGContextShowGlyphsAtPositions(c, glyphs.data(), positions.data(), glyphs.size());
    }
    if (clip) {
        if (!in.text_clip)
            in.text_clip = CGPathCreateMutable();
        for (size_t i = 0; i < glyphs.size(); i++)
            if (CGPathRef g = glyph_outline(f->cg, glyphs[i])) {
                CGAffineTransform place = CGAffineTransformConcat(CGAffineTransformMakeScale(st.Tfs, st.Tfs),
                                                                  CGAffineTransformTranslate(tm, positions[i].x, 0));
                CGPathAddPath(in.text_clip, &place, g);
                CFRelease(g);
            }
    }
}

#pragma mark - Operators

static void
op_q(Interp &in)
{
    CGContextSaveGState(in.c);
    in.saves++;
    in.stack.push_back(State(in.st()));
}

static void
op_Q(Interp &in, size_t floor)
{
    if (in.stack.size() <= floor || in.saves <= 0)
        return;
    CGContextRestoreGState(in.c);
    in.saves--;
    in.stack.pop_back();
}

static void
run_content(Interp &in, const uint8_t *bytes, size_t n)
{
    CGContextRef c = in.c;
    CGPDFArena arena;
    CGPDFContentReader reader(bytes, n, arena, in.d);
    CGPDFOperation op;
    size_t floor = in.stack.size();
    std::vector<CGPDFObject> ops;
    while (reader.next(op)) {
        ops.insert(ops.end(), op.operands.begin(), op.operands.end());
        const char *o = op.op;
        if (strcmp(o, "BI") && !CGPDFIsOperator(o))
            continue;  /* operands wait for a real operator */
        size_t k = ops.size();
        auto arg = [&](size_t i, size_t count) { return k >= count ? num(ops[k - count + i]) : 0.0; };
        State &s = in.st();
        switch (o[0]) {
        case 'q': if (!o[1]) op_q(in); break;
        case 'Q': if (!o[1]) op_Q(in, floor); break;
        case 'c':
            if (!strcmp(o, "cm") && k >= 6) {
                CGContextConcatCTM(c, CGAffineTransformMake(arg(0, 6), arg(1, 6), arg(2, 6), arg(3, 6), arg(4, 6), arg(5, 6)));
            } else if (!strcmp(o, "c") && k >= 6) {
                CGContextAddCurveToPoint(c, arg(0, 6), arg(1, 6), arg(2, 6), arg(3, 6), arg(4, 6), arg(5, 6));
            } else if (!strcmp(o, "cs") && k >= 1) {
                set_space(in, false, &ops[k - 1]);
            }
            break;
        case 'm': if (!o[1] && k >= 2) CGContextMoveToPoint(c, arg(0, 2), arg(1, 2)); break;
        case 'l': if (!o[1] && k >= 2) CGContextAddLineToPoint(c, arg(0, 2), arg(1, 2)); break;
        case 'v':
            if (k >= 4) {
                CGPoint cur = CGContextIsPathEmpty(c) ? CGPointZero : CGContextGetPathCurrentPoint(c);
                CGContextAddCurveToPoint(c, cur.x, cur.y, arg(0, 4), arg(1, 4), arg(2, 4), arg(3, 4));
            }
            break;
        case 'y': if (k >= 4) CGContextAddCurveToPoint(c, arg(0, 4), arg(1, 4), arg(2, 4), arg(3, 4), arg(2, 4), arg(3, 4)); break;
        case 'h': CGContextClosePath(c); break;
        case 'r':
            if (!strcmp(o, "re") && k >= 4) {
                double x = arg(0, 4), y = arg(1, 4), w = arg(2, 4), h = arg(3, 4);
                /* m, l, l, l, h as the specification defines it (CGContextAddRect normalizes) */
                CGContextMoveToPoint(c, x, y);
                CGContextAddLineToPoint(c, x + w, y);
                CGContextAddLineToPoint(c, x + w, y + h);
                CGContextAddLineToPoint(c, x, y + h);
                CGContextClosePath(c);
            } else if (!strcmp(o, "rg") && k >= 3) {
                set_device(in, false, "DeviceRGB", std::vector<CGPDFObject>(ops.end() - 3, ops.end()));
            } else if (!strcmp(o, "ri") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeName) {
                const char *ri = ops[k - 1].name;
                CGContextSetRenderingIntent(c, !strcmp(ri, "Perceptual") ? kCGRenderingIntentPerceptual
                                               : !strcmp(ri, "Saturation") ? kCGRenderingIntentSaturation
                                               : !strcmp(ri, "AbsoluteColorimetric") ? kCGRenderingIntentAbsoluteColorimetric
                                                                                     : kCGRenderingIntentRelativeColorimetric);
            }
            break;
        case 'R': if (!strcmp(o, "RG") && k >= 3) set_device(in, true, "DeviceRGB", std::vector<CGPDFObject>(ops.end() - 3, ops.end())); break;
        case 'g':
            if (!o[1] && k >= 1)
                set_device(in, false, "DeviceGray", std::vector<CGPDFObject>(ops.end() - 1, ops.end()));
            else if (!strcmp(o, "gs") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeName)
                ext_gstate(in, ops[k - 1].name);
            break;
        case 'G': if (!o[1] && k >= 1) set_device(in, true, "DeviceGray", std::vector<CGPDFObject>(ops.end() - 1, ops.end())); break;
        case 'k': if (!o[1] && k >= 4) set_device(in, false, "DeviceCMYK", std::vector<CGPDFObject>(ops.end() - 4, ops.end())); break;
        case 'K': if (!o[1] && k >= 4) set_device(in, true, "DeviceCMYK", std::vector<CGPDFObject>(ops.end() - 4, ops.end())); break;
        case 'C': if (!strcmp(o, "CS") && k >= 1) set_space(in, true, &ops[k - 1]); break;
        case 's':
            if (!strcmp(o, "sc") || !strcmp(o, "scn")) {
                set_components(in, false, ops);
            } else if (!strcmp(o, "s")) {
                CGContextClosePath(c);
                paint(in, kCGPathStroke);
            } else if (!strcmp(o, "sh") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeName) {
                if (CGPDFObjectRef sh = in.resource("Shading", ops[k - 1].name)) {
                    in.pending_clip = 0;
                    shading_object(in, sh, false);
                }
            }
            break;
        case 'S':
            if (!o[1])
                paint(in, kCGPathStroke);
            else if (!strcmp(o, "SC") || !strcmp(o, "SCN"))
                set_components(in, true, ops);
            break;
        case 'f':
            if (!o[1])
                paint(in, kCGPathFill);
            else if (!strcmp(o, "f*"))
                paint(in, kCGPathEOFill);
            break;
        case 'F': paint(in, kCGPathFill); break;
        case 'B':
            if (!o[1]) {
                paint(in, kCGPathFillStroke);
            } else if (!strcmp(o, "B*")) {
                paint(in, kCGPathEOFillStroke);
            } else if (!strcmp(o, "BT")) {
                in.Tm = in.Tlm = CGAffineTransformIdentity;
            } else if (!strcmp(o, "BI") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeStream) {
                CGContextSaveGState(c);
                draw_image(in, ops[k - 1].stream, true);
                CGContextRestoreGState(c);
            }
            break;
        case 'b':
            CGContextClosePath(c);
            paint(in, !strcmp(o, "b*") ? kCGPathEOFillStroke : kCGPathFillStroke);
            break;
        case 'n': if (!o[1]) paint(in, kNoPaint); break;
        case 'W': in.pending_clip = !strcmp(o, "W*") ? 2 : 1; break;
        case 'w': if (!o[1] && k >= 1) CGContextSetLineWidth(c, arg(0, 1)), s.line_width = arg(0, 1); break;
        case 'J': if (k >= 1) CGContextSetLineCap(c, (CGLineCap)(int)arg(0, 1)); break;
        case 'j': if (k >= 1) CGContextSetLineJoin(c, (CGLineJoin)(int)arg(0, 1)); break;
        case 'M': if (!o[1] && k >= 1) CGContextSetMiterLimit(c, arg(0, 1)); break;
        case 'i': if (k >= 1) CGContextSetFlatness(c, arg(0, 1)); break;
        case 'd':
            if (!o[1] && k >= 2 && ops[k - 2].type == kCGPDFObjectTypeArray) {
                Vec l;
                numbers(ops[k - 2].array, l);
                std::vector<CGFloat> cl(l.begin(), l.end());
                CGContextSetLineDash(c, num(ops[k - 1]), cl.empty() ? NULL : cl.data(), cl.size());
            } else if (!strcmp(o, "d1")) {
                in.uncolored = true;
            }
            break;
        case 'D':
            if (!strcmp(o, "Do") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeName) {
                CGPDFObjectRef xo = in.resource("XObject", ops[k - 1].name);
                CGPDFStreamRef xs;
                const char *sub = NULL;
                if (xo && CGPDFObjectGetValue(xo, kCGPDFObjectTypeStream, &xs) &&
                    CGPDFDictionaryGetName(CGPDFStreamGetDictionary(xs), "Subtype", &sub)) {
                    if (!strcmp(sub, "Image"))
                        draw_image(in, xs, false);
                    else if (!strcmp(sub, "Form"))
                        do_form(in, xs);
                }
            }
            break;
        case 'T':
            if (!strcmp(o, "Tf") && k >= 2 && ops[k - 2].type == kCGPDFObjectTypeName) {
                s.font = font_for(in, object_dict(in.resource("Font", ops[k - 2].name)));
                s.Tfs = num(ops[k - 1]);
            } else if (!strcmp(o, "Tc") && k >= 1) {
                s.Tc = arg(0, 1);
            } else if (!strcmp(o, "Tw") && k >= 1) {
                s.Tw = arg(0, 1);
            } else if (!strcmp(o, "Tz") && k >= 1) {
                s.Th = arg(0, 1) / 100;
            } else if (!strcmp(o, "TL") && k >= 1) {
                s.TL = arg(0, 1);
            } else if (!strcmp(o, "Ts") && k >= 1) {
                s.rise = arg(0, 1);
            } else if (!strcmp(o, "Tr") && k >= 1) {
                s.Tr = std::max(0, std::min(7, (int)arg(0, 1)));
            } else if ((!strcmp(o, "Td") || !strcmp(o, "TD")) && k >= 2) {
                if (o[1] == 'D')
                    s.TL = -arg(1, 2);
                in.Tlm = in.Tm = CGAffineTransformConcat(CGAffineTransformMakeTranslation(arg(0, 2), arg(1, 2)), in.Tlm);
            } else if (!strcmp(o, "Tm") && k >= 6) {
                in.Tlm = in.Tm = CGAffineTransformMake(arg(0, 6), arg(1, 6), arg(2, 6), arg(3, 6), arg(4, 6), arg(5, 6));
            } else if (!strcmp(o, "T*")) {
                in.Tlm = in.Tm = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, -s.TL), in.Tlm);
            } else if (!strcmp(o, "Tj") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeString) {
                show_text(in, ops[k - 1].string->bytes, ops[k - 1].string->length);
            } else if (!strcmp(o, "TJ") && k >= 1 && ops[k - 1].type == kCGPDFObjectTypeArray) {
                for (auto &item : ops[k - 1].array->items) {
                    if (item.type == kCGPDFObjectTypeString) {
                        show_text(in, item.string->bytes, item.string->length);
                    } else if (item.type == kCGPDFObjectTypeInteger || item.type == kCGPDFObjectTypeReal) {
                        Font *f = in.st().font;
                        double tx = -num(item) / 1000 * in.st().Tfs * in.st().Th;
                        if (f && f->vertical)
                            tx = 0;
                        in.Tm = CGAffineTransformConcat(CGAffineTransformMakeTranslation(tx, 0), in.Tm);
                    }
                }
            }
            break;
        case '\'':
        case '"':
            if (o[0] == '"' && k >= 3) {
                s.Tw = arg(0, 3), s.Tc = arg(1, 3);
            }
            in.Tlm = in.Tm = CGAffineTransformConcat(CGAffineTransformMakeTranslation(0, -s.TL), in.Tlm);
            if (k >= 1 && ops[k - 1].type == kCGPDFObjectTypeString)
                show_text(in, ops[k - 1].string->bytes, ops[k - 1].string->length);
            break;
        case 'E':
            if (!strcmp(o, "ET") && in.text_clip) {
                CGContextClipToUserPath(c, in.text_clip, false);
                CFRelease(in.text_clip);
                in.text_clip = NULL;
            } else if (!strcmp(o, "ET") && in.st().Tr >= 4) {
                /* a clip mode with no glyphs clips everything away */
            }
            break;
        default: break;
        }
        ops.clear();
    }
    /* unbalanced saves are undone at the end of the stream */
    while (in.stack.size() > floor && in.saves > 0) {
        CGContextRestoreGState(c);
        in.saves--;
        in.stack.pop_back();
    }
}

}  // namespace

#pragma mark - Drawing a page

void
CGContextDrawPDFPage(CGContextRef c, CGPDFPageRef page)
{
    CGPDFDocData *d = CGPDFPageGetDocData(page);
    if (!c || !page || !d || (d->crypt.encrypted && !d->crypt.unlocked))
        return;
    CGPDFContentStreamRef cs = CGPDFContentStreamCreateWithPage(page);
    CFArrayRef streams = CGPDFContentStreamGetStreams(cs);
    std::vector<uint8_t> bytes;
    for (CFIndex i = 0; streams && i < CFArrayGetCount(streams); i++) {
        CFDataRef data = CGPDFStreamDecode((CGPDFStreamRef)CFArrayGetValueAtIndex(streams, i), NULL, false);
        if (!data)
            continue;
        bytes.insert(bytes.end(), CFDataGetBytePtr(data), CFDataGetBytePtr(data) + CFDataGetLength(data));
        bytes.push_back('\n');
        CFRelease(data);
    }
    CGAffineTransform text_matrix = CGContextGetTextMatrix(c);
    CGContextSaveGState(c);
    /* the initial graphics state (section 8.4.1) */
    CGContextSetLineWidth(c, 1);
    CGContextSetLineCap(c, kCGLineCapButt);
    CGContextSetLineJoin(c, kCGLineJoinMiter);
    CGContextSetMiterLimit(c, 10);
    CGContextSetLineDash(c, 0, NULL, 0);
    CGContextSetAlpha(c, 1);
    CGContextSetBlendMode(c, kCGBlendModeNormal);
    CGContextSetCharacterSpacing(c, 0);
    CGContextBeginPath(c);
    std::unordered_map<CGPDFDictionaryRef, std::unique_ptr<Font>> fonts;
    Interp in;
    in.c = c;
    in.d = d;
    in.fonts = &fonts;
    in.stack.push_back(State());
    in.st().fill_cs = in.st().stroke_cs = device_space("DeviceGray");
    in.st().fill = in.st().stroke = {0};
    in.resources.push_back(CGPDFContentStreamGetResources(cs));
    in.pattern_base.push_back(CGContextGetCTM(c));
    apply_colors(in);
    {
        std::lock_guard<std::recursive_mutex> guard(d->lock);
        run_content(in, bytes.data(), bytes.size());
    }
    if (in.text_clip)
        CFRelease(in.text_clip);
    CGContextRestoreGState(c);
    CGContextSetTextMatrix(c, text_matrix);
    CGPDFContentStreamRelease(cs);
}

void
CGContextDrawPDFDocument(CGContextRef c, CGRect rect, CGPDFDocumentRef doc, int number)
{
    CGPDFPageRef page = number > 0 ? CGPDFDocumentGetPage(doc, (size_t)number) : NULL;
    if (!c || !page)
        return;
    /* the media box scaled into the rectangle, as the deprecated call did */
    CGRect media = CGPDFPageGetBoxRect(page, kCGPDFMediaBox);
    if (media.size.width <= 0 || media.size.height <= 0)
        return;
    CGContextSaveGState(c);
    CGContextTranslateCTM(c, rect.origin.x, rect.origin.y);
    CGContextScaleCTM(c, rect.size.width / media.size.width, rect.size.height / media.size.height);
    CGContextTranslateCTM(c, -media.origin.x, -media.origin.y);
    CGContextDrawPDFPage(c, page);
    CGContextRestoreGState(c);
}
