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
    union {
        char *str;
        SV *sv;
    } ori;
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

#define ENCODE_UTF8(data, USE_SHADOW, USE_SHADOW_NV) { \
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
        if( SvNOK(data) ) { \
            USE_SHADOW_NV; \
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
            SvPV_set(data, shadow->ori.str); \
            shadow = shadow->next; \
        }, \
        { \
            SvUPGRADE(data, SVt_RV); \
            SvROK_on(data); \
            SvRV_set(data, shadow->ori.sv); \
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

#define MOVING_CHECK_UTF8_TAIL(head_bound, need_len, head_mask, body_mask) \
    if( *p < head_bound ){ \
        if( len < need_len || ((*p & head_mask) == 0 && (*(p+1) & body_mask) == 0) || (need_len==4 && (*p>0xF4 || (*p==0xF4 && *(p+1)>=0x90))) ) \
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
            p += need_len; \
            len -= need_len; \
        } \
    }

#define MOVING_CHECK_WRITE_UTF8_TAIL(head_bound, need_len, head_mask, body_mask) \
    if( *p < head_bound ){ \
        if( len < need_len || ((*p & head_mask) == 0 && (*(p+1) & body_mask) == 0) || (need_len==4 && (*p>0xF4 || (*p==0xF4 && *(p+1)>=0x90))) ){ \
            *q++ = '?'; \
            --len; \
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
        if(0){ \
            STRLEN i; \
            STRLEN len; \
            unsigned char * p = (unsigned char*)SvPV(sv, len); \
            printf("before utf8 on\n"); \
            for(i=0; i<len; ++i) \
                printf("%02X ", (unsigned int)p[i]); \
            puts(""); \
        } \
        while( len ){ \
            if( *p < 0x80 ){ /* 0xxxxxxx (len=1) */ \
                ++p; \
                --len; \
            } \
            else if( *p < 0xC0 ){ /* 10xxxxxx (illegal head) */ \
                break; \
            } \
            else MOVING_CHECK_UTF8_TAIL(0xE0, 2, 0x1E, 0x00) /* 110xxxxx (len=2) */ \
            else MOVING_CHECK_UTF8_TAIL(0xF0, 3, 0x0F, 0x20) /* 1110xxxx (len=3) */ \
            else MOVING_CHECK_UTF8_TAIL(0xF8, 4, 0x07, 0x30) /* 11110xxx (len=4) */ \
            /* else MOVING_CHECK_UTF8_TAIL(0xFC, 5, 0x03, 0x38) */ /* no 111110xx (len=5) */ \
            /* else MOVING_CHECK_UTF8_TAIL(0xFE, 6, 0x01, 0x3C) */ /* no 1111110x (len=6) */ \
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
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xE0, 2, 0x1E, 0x00) /* 110xxxxx (len=2) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xF0, 3, 0x0F, 0x20) /* 1110xxxx (len=3) */ \
                else MOVING_CHECK_WRITE_UTF8_TAIL(0xF8, 4, 0x07, 0x30) /* 11110xxx (len=4) */ \
                /* else MOVING_CHECK_WRITE_UTF8_TAIL(0xFC, 5, 0x03, 0x38) */ /* no 111110xx (len=5) */ \
                /* else MOVING_CHECK_WRITE_UTF8_TAIL(0xFE, 6, 0x01, 0x3C) */ /* no 1111110x (len=6) */ \
                else { /* 1111111x (illegal head) */ \
                    ++p; \
                    *q++ = '?'; \
                    --len; \
                } \
            } \
        } \
        if(0){ \
            STRLEN i; \
            STRLEN len; \
            unsigned char * p = (unsigned char*)SvPV(sv, len); \
            printf("after utf8 on\n"); \
            for(i=0; i<len; ++i) \
                printf("%02X ", (unsigned int)p[i]); \
            puts(""); \
        } \
        SvUTF8_on(sv); \
    }

void
encode_utf8(SV *data)
    CODE:
        ENCODE_UTF8(data, /* */, ;);

#define DECODE_UTF8(data, FORK_TO_HINT_TABLE, SAVE_ORI_SV_TO_HINT_TABLE) { \
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
            U32 ref_type = SvTYPE(deref); \
            if( ref_type==SVt_PVAV ){ \
                SV **arr = AvARRAY((AV*)deref); \
                I32 i; \
                for(i=av_len((AV*)deref); i>=0; --i){ \
                    *p++ = arr[i]; \
                    SHIFT_AND_EXTEND_JSON2_STACK; \
                } \
                continue; \
            } \
            if( ref_type==SVt_PVHV ){ \
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
            if( ref_type < SVt_PVAV ) { \
                SAVE_ORI_SV_TO_HINT_TABLE; \
                sv_force_normal_flags(data, SV_COW_DROP_PV); \
                sv_setnv(data, SvNV(deref)); \
                continue; \
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
        DECODE_UTF8(data, q = p;, ;);

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
                struct Shadow_t *new_shadow = (struct Shadow_t*) safemalloc(sizeof(struct Shadow_t) + total_len + 1); \
                char *new_str = new_shadow->new_str; \
                char *ori_str; \
                SvOOK_off(sv); \
                ori_str = SvPVX(sv); \
                new_shadow->ori.str = ori_str; \
                SvPV_set(sv, new_str); \
                shadow_tail->next = new_shadow; \
                shadow_tail = new_shadow; \
                Copy(ori_str, new_str, total_len-len, char); \
                q = (unsigned char*)new_str + (p - (unsigned char*)ori_str); \
                new_str[total_len] = 0; \
            }, \
            { \
                struct Shadow_t *new_shadow = (struct Shadow_t*) safemalloc(sizeof(struct Shadow_t)); \
                new_shadow->ori.sv = deref; \
                shadow_tail->next = new_shadow; \
                shadow_tail = new_shadow; \
                SvREFCNT_inc_void_NN(deref); \
            } \
        );
        shadow_tail->next = NULL;
        hook->shadow = shadow_head.next;
        SAVEDESTRUCTOR_X(shadow_free, hook);
        ENTER;
