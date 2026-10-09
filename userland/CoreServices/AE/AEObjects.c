/* SPDX-License-Identifier: MIT OR Apache-2.0 */
/*
 * The Object Support Library (AEObjects.h, AEPackObject.h): building
 * object specifiers and resolving them through the accessors an app
 * installs. AEResolve resolves the container first (a null container is a
 * null token of class 'null'), then calls the accessor for the wanted class
 * and the container token's type (wildcards allowed; application table
 * before system), passing the container's wanted class, and disposes of the
 * container token afterwards. Tests (whose clauses) and ranges reach the
 * accessor as their raw descriptors.
 */
#include "AE_Finch.h"
#include <pthread.h>

#pragma mark - Building specifiers

static OSErr
record_of(DescType type, AEDesc *out)
{
    OSErr e = AECreateList(NULL, 0, true, out);
    if (!e)
        out->descriptorType = type;
    return e;
}

static OSErr
put_code(AEDesc *rec, AEKeyword key, DescType type, OSType code)
{
    return AEPutParamPtr(rec, key, type, &code, 4);
}

static void
dispose_inputs(Boolean dispose, AEDesc *a, AEDesc *b)
{
    if (!dispose)
        return;
    if (a)
        AEDisposeDesc(a);
    if (b)
        AEDisposeDesc(b);
}

OSErr
CreateOffsetDescriptor(long theOffset, AEDesc *theDescriptor)
{
    SInt32 v = (SInt32)theOffset;
    return AECreateDesc(typeSInt32, &v, 4, theDescriptor);
}

OSErr
CreateCompDescriptor(DescType comparisonOperator, AEDesc *operand1, AEDesc *operand2, Boolean disposeInputs,
                     AEDesc *theDescriptor)
{
    OSErr e = record_of(typeCompDescriptor, theDescriptor);
    if (!e && !(e = put_code(theDescriptor, keyAECompOperator, typeEnumerated, comparisonOperator)) &&
        !(e = AEPutParamDesc(theDescriptor, keyAEObject1, operand1)))
        e = AEPutParamDesc(theDescriptor, keyAEObject2, operand2);
    dispose_inputs(disposeInputs, operand1, operand2);
    return e;
}

OSErr
CreateLogicalDescriptor(AEDescList *theLogicalTerms, DescType theLogicOperator, Boolean disposeInputs,
                        AEDesc *theDescriptor)
{
    OSErr e = record_of(typeLogicalDescriptor, theDescriptor);
    if (!e && !(e = AEPutParamDesc(theDescriptor, keyAELogicalTerms, theLogicalTerms)))
        e = put_code(theDescriptor, keyAELogicalOperator, typeEnumerated, theLogicOperator);
    dispose_inputs(disposeInputs, theLogicalTerms, NULL);
    return e;
}

OSErr
CreateObjSpecifier(DescType desiredClass, AEDesc *theContainer, DescType keyForm, AEDesc *keyData,
                   Boolean disposeInputs, AEDesc *objSpecifier)
{
    AEDesc none = {typeNull, NULL};
    OSErr e = record_of(typeObjectSpecifier, objSpecifier);
    if (!e && !(e = put_code(objSpecifier, keyAEDesiredClass, typeType, desiredClass)) &&
        !(e = AEPutParamDesc(objSpecifier, keyAEContainer, theContainer ? theContainer : &none)) &&
        !(e = put_code(objSpecifier, keyAEKeyForm, typeEnumerated, keyForm)))
        e = AEPutParamDesc(objSpecifier, keyAEKeyData, keyData ? keyData : &none);
    dispose_inputs(disposeInputs, theContainer, keyData);
    return e;
}

OSErr
CreateRangeDescriptor(AEDesc *rangeStart, AEDesc *rangeStop, Boolean disposeInputs, AEDesc *theDescriptor)
{
    OSErr e = record_of(typeRangeDescriptor, theDescriptor);
    if (!e && !(e = AEPutParamDesc(theDescriptor, keyAERangeStart, rangeStart)))
        e = AEPutParamDesc(theDescriptor, keyAERangeStop, rangeStop);
    dispose_inputs(disposeInputs, rangeStart, rangeStop);
    return e;
}

#pragma mark - Accessors and callbacks

struct accessor {
    DescType desiredClass, containerType;
    OSLAccessorUPP proc;
    SRefCon refcon;
};

static struct {
    struct accessor *v;
    long count;
} tables[2];
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static struct {
    OSLCompareUPP compare;
    OSLCountUPP count;
    OSLDisposeTokenUPP disposeToken;
    OSLGetMarkTokenUPP getMarkToken;
    OSLMarkUPP mark;
    OSLAdjustMarksUPP adjustMarks;
    OSLGetErrDescUPP getErrDesc;
} callbacks;

OSErr AEObjectInit(void) { return noErr; }

OSErr
AESetObjectCallbacks(OSLCompareUPP myCompareProc, OSLCountUPP myCountProc, OSLDisposeTokenUPP myDisposeTokenProc,
                     OSLGetMarkTokenUPP myGetMarkTokenProc, OSLMarkUPP myMarkProc, OSLAdjustMarksUPP myAdjustMarksProc,
                     OSLGetErrDescUPP myGetErrDescProcPtr)
{
    callbacks.compare = myCompareProc;
    callbacks.count = myCountProc;
    callbacks.disposeToken = myDisposeTokenProc;
    callbacks.getMarkToken = myGetMarkTokenProc;
    callbacks.mark = myMarkProc;
    callbacks.adjustMarks = myAdjustMarksProc;
    callbacks.getErrDesc = myGetErrDescProcPtr;
    return noErr;
}

static struct accessor *
find_exact(int sys, DescType cls, DescType container)
{
    for (long i = 0; i < tables[sys].count; i++)
        if (tables[sys].v[i].desiredClass == cls && tables[sys].v[i].containerType == container)
            return &tables[sys].v[i];
    return NULL;
}

OSErr
AEInstallObjectAccessor(DescType desiredClass, DescType containerType, OSLAccessorUPP theAccessor,
                        SRefCon accessorRefcon, Boolean isSysHandler)
{
    if (!theAccessor)
        return paramErr;
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct accessor *a = find_exact(sys, desiredClass, containerType);
    if (!a) {
        struct accessor *v = realloc(tables[sys].v, (tables[sys].count + 1) * sizeof *v);
        if (!v) {
            pthread_mutex_unlock(&lock);
            return memFullErr;
        }
        tables[sys].v = v;
        a = &v[tables[sys].count++];
    }
    *a = (struct accessor){desiredClass, containerType, theAccessor, accessorRefcon};
    pthread_mutex_unlock(&lock);
    return noErr;
}

OSErr
AERemoveObjectAccessor(DescType desiredClass, DescType containerType, OSLAccessorUPP theAccessor, Boolean isSysHandler)
{
    int sys = isSysHandler ? 1 : 0;
    pthread_mutex_lock(&lock);
    struct accessor *a = find_exact(sys, desiredClass, containerType);
    OSErr e = errAEAccessorNotFound;
    if (a && (!theAccessor || a->proc == theAccessor)) {
        long i = a - tables[sys].v;
        memmove(a, a + 1, (tables[sys].count - i - 1) * sizeof *a);
        tables[sys].count--;
        e = noErr;
    }
    pthread_mutex_unlock(&lock);
    return e;
}

OSErr
AEGetObjectAccessor(DescType desiredClass, DescType containerType, OSLAccessorUPP *accessor, SRefCon *accessorRefcon,
                    Boolean isSysHandler)
{
    pthread_mutex_lock(&lock);
    struct accessor *a = find_exact(isSysHandler ? 1 : 0, desiredClass, containerType);
    if (a) {
        if (accessor)
            *accessor = a->proc;
        if (accessorRefcon)
            *accessorRefcon = a->refcon;
    }
    pthread_mutex_unlock(&lock);
    return a ? noErr : errAEAccessorNotFound;
}

static bool
lookup(DescType cls, DescType container, struct accessor *out)
{
    DescType c[] = {cls, cls, typeWildCard, typeWildCard};
    DescType k[] = {container, typeWildCard, container, typeWildCard};
    bool found = false;
    pthread_mutex_lock(&lock);
    for (int sys = 0; sys < 2 && !found; sys++)
        for (int i = 0; i < 4 && !found; i++) {
            struct accessor *a = find_exact(sys, c[i], k[i]);
            if (a) {
                *out = *a;
                found = true;
            }
        }
    pthread_mutex_unlock(&lock);
    return found;
}

OSErr
AECallObjectAccessor(DescType desiredClass, const AEDesc *containerToken, DescType containerClass, DescType keyForm,
                     const AEDesc *keyData, AEDesc *token)
{
    struct accessor a;
    if (!lookup(desiredClass, containerToken->descriptorType, &a))
        return errAEAccessorNotFound;
    return a.proc(desiredClass, containerToken, containerClass, keyForm, keyData, token, a.refcon);
}

OSErr
AEDisposeToken(AEDesc *theToken)
{
    if (callbacks.disposeToken)
        return callbacks.disposeToken(theToken);
    return AEDisposeDesc(theToken);
}

#pragma mark - Resolving

static OSErr
resolve(const AEDesc *spec, AEDesc *token, DescType *tokenClass)
{
    AEInitializeDesc(token);
    if (spec->descriptorType != typeObjectSpecifier || !AECheckIsRecord(spec))
        return errAENotAnObjSpec;
    DescType want = 0, form = 0, t;
    Size n;
    OSErr e;
    if ((e = AEGetParamPtr(spec, keyAEDesiredClass, typeType, &t, &want, 4, &n)) ||
        (e = AEGetParamPtr(spec, keyAEKeyForm, typeEnumerated, &t, &form, 4, &n)))
        return errAENotAnObjSpec;
    AEDesc container, data, containerToken = {typeNull, NULL};
    DescType containerClass = typeNull;
    if (AEGetParamDesc(spec, keyAEContainer, typeWildCard, &container))
        AEInitializeDesc(&container);
    if (AEGetParamDesc(spec, keyAEKeyData, typeWildCard, &data))
        AEInitializeDesc(&data);
    if (container.descriptorType == typeObjectSpecifier) {
        e = resolve(&container, &containerToken, &containerClass);
    } else if (container.descriptorType != typeNull) {
        containerClass = container.descriptorType;
        e = AEDuplicateDesc(&container, &containerToken);
    }
    if (!e) {
        struct accessor a;
        if (!lookup(want, containerToken.descriptorType, &a))
            e = errAEAccessorNotFound;
        else
            e = a.proc(want, &containerToken, containerClass, form, &data, token, a.refcon);
        if (e)
            AEInitializeDesc(token);
        if (containerToken.descriptorType != typeNull || containerToken.dataHandle)
            AEDisposeToken(&containerToken);
    }
    AEDisposeDesc(&container);
    AEDisposeDesc(&data);
    *tokenClass = want;
    return e;
}

OSErr
AEResolve(const AEDesc *objectSpecifier, short callbackFlags, AEDesc *theToken)
{
    if (!objectSpecifier || !theToken)
        return paramErr;
    DescType cls;
    return resolve(objectSpecifier, theToken, &cls);
}

#pragma mark - UPPs

OSLAccessorUPP (NewOSLAccessorUPP)(OSLAccessorProcPtr userRoutine) { return userRoutine; }
OSLCompareUPP (NewOSLCompareUPP)(OSLCompareProcPtr userRoutine) { return userRoutine; }
OSLCountUPP (NewOSLCountUPP)(OSLCountProcPtr userRoutine) { return userRoutine; }
OSLDisposeTokenUPP (NewOSLDisposeTokenUPP)(OSLDisposeTokenProcPtr userRoutine) { return userRoutine; }
OSLGetMarkTokenUPP (NewOSLGetMarkTokenUPP)(OSLGetMarkTokenProcPtr userRoutine) { return userRoutine; }
OSLMarkUPP (NewOSLMarkUPP)(OSLMarkProcPtr userRoutine) { return userRoutine; }
OSLAdjustMarksUPP (NewOSLAdjustMarksUPP)(OSLAdjustMarksProcPtr userRoutine) { return userRoutine; }
OSLGetErrDescUPP (NewOSLGetErrDescUPP)(OSLGetErrDescProcPtr userRoutine) { return userRoutine; }
void (DisposeOSLAccessorUPP)(OSLAccessorUPP userUPP) {}
void (DisposeOSLCompareUPP)(OSLCompareUPP userUPP) {}
void (DisposeOSLCountUPP)(OSLCountUPP userUPP) {}
void (DisposeOSLDisposeTokenUPP)(OSLDisposeTokenUPP userUPP) {}
void (DisposeOSLGetMarkTokenUPP)(OSLGetMarkTokenUPP userUPP) {}
void (DisposeOSLMarkUPP)(OSLMarkUPP userUPP) {}
void (DisposeOSLAdjustMarksUPP)(OSLAdjustMarksUPP userUPP) {}
void (DisposeOSLGetErrDescUPP)(OSLGetErrDescUPP userUPP) {}

OSErr
(InvokeOSLAccessorUPP)(DescType desiredClass, const AEDesc *container, DescType containerClass, DescType form,
                     const AEDesc *selectionData, AEDesc *value, SRefCon accessorRefcon, OSLAccessorUPP userUPP)
{
    return userUPP(desiredClass, container, containerClass, form, selectionData, value, accessorRefcon);
}
OSErr (InvokeOSLCompareUPP)(DescType oper, const AEDesc *obj1, const AEDesc *obj2, Boolean *result, OSLCompareUPP userUPP)
{
    return userUPP(oper, obj1, obj2, result);
}
OSErr (InvokeOSLCountUPP)(DescType desiredType, DescType containerClass, const AEDesc *container, long *result,
                        OSLCountUPP userUPP)
{
    return userUPP(desiredType, containerClass, container, result);
}
OSErr (InvokeOSLDisposeTokenUPP)(AEDesc *unneededToken, OSLDisposeTokenUPP userUPP) { return userUPP(unneededToken); }
OSErr (InvokeOSLGetMarkTokenUPP)(const AEDesc *dContainerToken, DescType containerClass, AEDesc *result,
                               OSLGetMarkTokenUPP userUPP)
{
    return userUPP(dContainerToken, containerClass, result);
}
OSErr (InvokeOSLMarkUPP)(const AEDesc *dToken, const AEDesc *markToken, long index, OSLMarkUPP userUPP)
{
    return userUPP(dToken, markToken, index);
}
OSErr (InvokeOSLAdjustMarksUPP)(long newStart, long newStop, const AEDesc *markToken, OSLAdjustMarksUPP userUPP)
{
    return userUPP(newStart, newStop, markToken);
}
OSErr (InvokeOSLGetErrDescUPP)(AEDesc **appDescPtr, OSLGetErrDescUPP userUPP) { return userUPP(appDescPtr); }
