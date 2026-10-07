// Copyright (c) 2026 The Finch Project contributors.
// SPDX-License-Identifier: MIT OR Apache-2.0
//
// numpunct_byname<char|wchar_t>::__init(const char*): Apple's libc++ still
// exports this private helper; upstream LLVM 22 folded it into the
// constructors. Finch keeps the symbol: it reads the locale's decimal point,
// thousands separator and grouping, like the constructors do.

#include <locale>
#include <stdexcept>
#include <string>

#include <locale.h>
#include <string.h>
#include <wchar.h>
#include <xlocale.h>

namespace {

struct named_locale {
	locale_t loc;
	explicit named_locale(const char *name) : loc(newlocale(LC_ALL_MASK, name, nullptr)) {}
	~named_locale() { if (loc) freelocale(loc); }
};

// One wide character from a locale string, or false if it isn't exactly one.
bool to_wchar(wchar_t &out, const char *s, locale_t loc)
{
	mbstate_t st{};
	wchar_t wc;
	size_t len = strlen(s);
	size_t n = mbrtowc_l(&wc, s, len, &st, loc);
	if (n == 0 || n == (size_t)-1 || n == (size_t)-2 || n != len)
		return false;
	out = wc;
	return true;
}

// One narrow character: a single byte, or a no-break space mapped to ' '.
bool to_char(char &out, const char *s, locale_t loc)
{
	if (s[0] != '\0' && s[1] == '\0') {
		out = s[0];
		return true;
	}
	wchar_t wc;
	if (!to_wchar(wc, s, loc))
		return false;
	if (wc == L' ' || wc == L' ') {
		out = ' ';
		return true;
	}
	return false;
}

[[noreturn]] void fail(const char *what, const char *name)
{
	throw std::runtime_error(std::string(what) + " failed to construct for " + name);
}

} // namespace

namespace std {
inline namespace __1 {

void numpunct_byname<char>::__init(const char *nm)
{
	if (strcmp(nm, "C") == 0)
		return;
	named_locale l(nm);
	if (!l.loc)
		fail("numpunct_byname<char>::numpunct_byname", nm);
	struct lconv *lc = localeconv_l(l.loc);
	if (!to_char(__decimal_point_, lc->decimal_point, l.loc))
		__decimal_point_ = numpunct<char>::do_decimal_point();
	if (!to_char(__thousands_sep_, lc->thousands_sep, l.loc))
		__thousands_sep_ = numpunct<char>::do_thousands_sep();
	__grouping_ = lc->grouping;
}

void numpunct_byname<wchar_t>::__init(const char *nm)
{
	if (strcmp(nm, "C") == 0)
		return;
	named_locale l(nm);
	if (!l.loc)
		fail("numpunct_byname<wchar_t>::numpunct_byname", nm);
	struct lconv *lc = localeconv_l(l.loc);
	to_wchar(__decimal_point_, lc->decimal_point, l.loc);
	to_wchar(__thousands_sep_, lc->thousands_sep, l.loc);
	__grouping_ = lc->grouping;
}

} // namespace __1
} // namespace std
