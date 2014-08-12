#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include "ppport.h"

#ifndef UNLIKELY
#  define UNLIKELY(x) (x)
#endif
#ifndef LIKELY
#  define LIKELY(x) (x)
#endif

#define JSON2_STACK_CELL_SIZE 1022
struct StackCell_t {
    struct StackCell_t *prev, *next;
    SV* slot[JSON2_STACK_CELL_SIZE];
};

struct Shadow_t {
    char *ori_str;
    struct Shadow_t *next;
    char new_str[0]; // var length
};

struct Hook_t {
    SV *root;
    struct Shadow_t *shadow;
};

#define SHIFT_AND_EXTEND_JSON2_STACK \
    if( p == curr->slot + JSON2_STACK_CELL_SIZE ){ \
        if( !curr->next ){ \
            struct StackCell_t *next; \
            Newx(next, 1, struct StackCell_t); \
            curr->next = next; \
            next->prev = curr; \
            next->next = NULL; \
        } \
        tail = curr = curr->next; \
        p = curr->slot; \
    }

#define ENCODE_UTF8(data, USE_SHADOW) { \
    struct StackCell_t head, *tail, *curr; \
    SV ** p; \
\
    curr = tail = &head; \
    p = head.slot; \
    head.prev = head.next = NULL; \
    *p++ = data; \
    while( p!=head.slot ){ \
        if( p == curr->slot ){ \
            curr = curr->prev; \
            p = curr->slot + JSON2_STACK_CELL_SIZE; \
        } \
        data = *--p; \
        if( SvROK(data) ){ \
            SV *deref = SvRV(data); \
            switch( SvTYPE(deref) ){ \
                case SVt_PVAV: \
                    { \
                        SV **arr = AvARRAY((AV*)deref); \
                        I32 i; \
                        for(i=av_len((AV*)deref); i>=0; --i){ \
                            *p++ = arr[i]; \
                            SHIFT_AND_EXTEND_JSON2_STACK; \
                        } \
                        continue; \
                    } \
                case SVt_PVHV: \
                    { \
                        HE *entry; \
                        hv_iterinit((HV*)deref); \
                        while( (entry = hv_iternext((HV*)deref)) ){ \
                            *p++ = HeVAL(entry); \
                            SHIFT_AND_EXTEND_JSON2_STACK; \
\
                            if( HeKLEN(entry)==HEf_SVKEY ){ \
                                SV *data = HeKEY_sv(entry); \
                                USE_SHADOW; \
                                SvUTF8_off(data); \
                            } \
                            else \
                                HEK_UTF8_off(HeKEY_hek(entry)); \
                        } \
                        continue; \
                    } \
                default: ; \
            } \
        } \
        if( SvPOK(data) ){ \
            USE_SHADOW; \
            SvUTF8_off(data); \
        } \
    } \
    while( tail!=&head ){ \
        curr = tail->prev; \
        safefree(tail); \
        tail = curr; \
    } \
}

static void shadow_free(pTHX_ void *hook)
{
    struct Shadow_t *shadow = ((struct Hook_t*)hook)->shadow;
    SV *data = ((struct Hook_t*)hook)->root;
    ENCODE_UTF8(data, \
        if( shadow && shadow->new_str==SvPVX(data) ){ \
            SvPV_set(data, shadow->ori_str); \
            shadow = shadow->next; \
        } \
    );
    shadow = ((struct Hook_t*)hook)->shadow;
    while( shadow ){
        struct Shadow_t *q = shadow->next;
        safefree(shadow);
        shadow = q;
    }
    Safefree(hook);
}

MODULE = JSON::XS::ByteString		PACKAGE = JSON::XS::ByteString		

#define MOVING_CHECK_UTF8_TAIL(head_bound, need_len) \
    if( *p < head_bound ){ \
        if( len < need_len ) \
            break; \
        { \
            unsigned char *q = p+1; \
            STRLEN checked_len = 1; \
            while( checked_len < need_len ){ \
                if( *q < 0x80 || 0xC0 <= *q ) \
                    break; \
                ++q; \
                ++checked_len; \
            } \
            if( checked_len < need_len ) \
                break; \
            else \
                p += need_len; \
            len -= need_len; \
        } \
    }

#define MOVING_CHECK_WRITE_UTF8_TAIL(head_bound, need_len) \
    if( *p < head_bound ){ \
        if( len < need_len ){ \
            *q = '?'; \
            while( --len ) \
                *++q = '?'; \
        } \
        else{ \
            unsigned char *qq = p+1; \
            STRLEN checked_len = 1; \
            while( checked_len < need_len ){ \
                if( *qq < 0x80 || 0xC0 <= *qq ) \
                    break; \
                ++qq; \
                ++checked_len; \
            } \
            if( checked_len < need_len ){ \
                for(checked_len=0; checked_len<need_len; ++checked_len) \
                    *q++ = '?'; \
                p += need_len; \
            } \
            else{ \
                for(checked_len=0; checked_len<need_len; ++checked_len) \
                    *q++ = *p++; \
            } \
            len -= need_len; \
        } \
    }

#define SAFE_SvUTF8_on(_sv, FORK_TO_HINT_TABLE) \
    { \
        SV *sv = _sv; \
        STRLEN len = SvCUR(sv); \
        unsigned char *p = (unsigned char*)SvPVX(sv); \
        STRLEN i; \
        while( len ){ \
            if( *p < 0x80 ){ /* 0xxxxxxx (len=1) */ \
                ++p; \
                --len; \
            } \
            else if( *p < 0xC0 ){ /* 10xxxxxx (illegal head) */ \
                break; \
            } \
            else MOVING_CHECK_UTF8_TAIL(0xE0, 2) /* 110xxxxx (len=2) */ \
            else MOVING_CHECK_UTF8_TAIL(0xF0, 3) /* 1110xxxx (len=3) */ \
            else MOVING_CHECK_UTF8_TAIL(0xF8, 4) /* 11110xxx (len=4) */ \
            else MOVING_CHECK_UTF8_TAIL(0xFC, 5) /* 111110xx (len=5) */ \
            else MOVING_CHECK_UTF8_TAIL(0xFE, 6) /* 1111110x (len=6) */ \
            else { /* 1111111x (illegal head) */ \
                break; \
            } \
        } \
        if( UNLIKELY(len) ){ /* found some illegal octet */ \
            unsigned char *q; \
            FORK_TO_HINT_TABLE; \
            while( len ){ \
                if( *p < 0x80 ){ /* 0xxxxxxx (len=1) */ \
                    *q++ = *p++; \
                    --len; \
                } \
                else if( *p < 0xC0 ){ /* 10xxxxxx (illegal head) */ \
                    ++p; \
                    *q++ = '?'; \
                    --len; \
                } \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xE0, 2) /* 110xxxxx (len=2) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xF0, 3) /* 1110xxxx (len=3) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xF8, 4) /* 11110xxx (len=4) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xFC, 5) /* 111110xx (len=5) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xFE, 6) /* 1111110x (len=6) */ \
                else { /* 1111111x (illegal head) */ \
                    ++p; \
                    *q++ = '?'; \
                    --len; \
                } \
            } \
        } \
        SvUTF8_on(sv); \
    }

void
encode_utf8(SV *data)
    CODE:
        ENCODE_UTF8(data, /* */);

#define DECODE_UTF8(data, FORK_TO_HINT_TABLE) { \
    struct StackCell_t head, *tail, *curr; \
    SV ** p; \
    SV *root = data; \
\
    curr = tail = &head; \
    p = head.slot; \
    head.prev = head.next = NULL; \
    *p++ = data; \
    while( p!=head.slot ){ \
        if( p == curr->slot ){ \
            curr = curr->prev; \
            p = curr->slot + JSON2_STACK_CELL_SIZE; \
        } \
        data = *--p; \
        if( SvROK(data) ){ \
            SV *deref = SvRV(data); \
            switch( SvTYPE(deref) ){ \
                case SVt_PVAV: \
                    { \
                        SV **arr = AvARRAY((AV*)deref); \
                        I32 i; \
                        for(i=av_len((AV*)deref); i>=0; --i){ \
                            *p++ = arr[i]; \
                            SHIFT_AND_EXTEND_JSON2_STACK; \
                        } \
                        continue; \
                    } \
                case SVt_PVHV: \
                    { \
                        HE *entry; \
                        hv_iterinit((HV*)deref); \
                        while( (entry = hv_iternext((HV*)deref)) ){ \
                            *p++ = HeVAL(entry); \
                            SHIFT_AND_EXTEND_JSON2_STACK; \
\
                            if( HeKLEN(entry)==HEf_SVKEY ) \
                                SAFE_SvUTF8_on(HeKEY_sv(entry), FORK_TO_HINT_TABLE) \
                            else \
                                HEK_UTF8_on(HeKEY_hek(entry)); \
                        } \
                        continue; \
                    } \
                default: ; \
            } \
        } \
        if( SvPOK(data) ){ \
            if( SvIsCOW(data) ) \
                sv_force_normal(data); \
            SAFE_SvUTF8_on(data, FORK_TO_HINT_TABLE) \
        } \
        else if( SvOK(data) ) \
            SvPVutf8_nolen(data); \
    } \
    while( tail!=&head ){ \
        curr = tail->prev; \
        safefree(tail); \
        tail = curr; \
    } \
}

void
decode_utf8(SV *data)
    CODE:
        DECODE_UTF8(data, q = p;);

void
decode_utf8_with_orig(SV *data)
    CODE:
        struct Hook_t *hook;
        struct Shadow_t shadow_head, *shadow_tail;
        shadow_tail = &shadow_head;

        Newx(hook, 1, struct Hook_t);
        hook->root = data;

        LEAVE;
        DECODE_UTF8(data, \
            { \
                STRLEN total_len = SvCUR(sv); \
                STRLEN i = total_len - len; \
                struct Shadow_t *new_shadow = (struct Shadow_t*) safemalloc(sizeof(struct Shadow_t) + total_len + 1); \
                char *new_str = new_shadow->new_str; \
                char *ori_str; \
                SvOOK_off(sv); \
                ori_str = SvPVX(sv); \
                new_shadow->ori_str = ori_str; \
                SvPV_set(sv, new_str); \
                shadow_tail->next = new_shadow; \
                shadow_tail = new_shadow; \
                Copy(ori_str, new_str, total_len-len, char); \
                q = (unsigned char*)new_str + (p - (unsigned char*)ori_str); \
                q[total_len] = 0; \
            } \
        );
        shadow_tail->next = NULL;
        hook->shadow = shadow_head.next;
        SAVEDESTRUCTOR_X(shadow_free, hook);
        ENTER;
