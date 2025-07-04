module types;

struct ComplexInt(T)
{
    align(1)
    {
        T re;
        T im;
    }

    this(T re, T im = 0)
    {
        this.re = re;
        this.im = im;
    }
}

unittest
{
    static assert(ComplexInt!byte.sizeof == 2);
    static assert(ComplexInt!short.sizeof == 4);
}


enum StreamerElementType : ubyte
{
    isComplex = 0b10000000,
    isFloat   = 0b01000000,     // (a & isFloat) == 0 => isInt
    isComplexFloat = isComplex | isFloat,
    isComplexInt = isComplex,
    isRealFloat = isFloat,
    isRealInt = 0b00000000,
    ComplexFloat32 = isComplexFloat | 1,
    ComplexFloat64 = isComplexFloat | 2,
    ComplexInt8    = isComplexInt | 1,
    ComplexInt16   = isComplexInt | 2,
}


bool isSameStreamerElementType(C)(StreamerElementType a)
{
    static if(is(typeof(C.init.re) == float))
        return a == StreamerElementType.ComplexFloat32;
    else static if(is(typeof(C.init.re) == double))
        return a == StreamerElementType.ComplexFloat64;
    else static if(is(typeof(C.init.re) == short))
        return a == StreamerElementType.ComplexInt16;
    else static if(is(typeof(C.init.re) == byte))
        return a == StreamerElementType.ComplexInt8;
    else
        static assert(0, "Unsupported type");    
}
