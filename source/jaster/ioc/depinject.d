module jaster.ioc.depinject;

/// Describes the lifetime of a service.
enum ServiceLifetime
{
    /// The service is constructed every single time it is requested.
    Transient,

    /// The service is only constructed a single time for every `ServiceProvider`, regardless of which scope is used to access it.
    Singleton,

    /++
     + This service is constructed once per scope.
     +
     + See_Also:
     +  `ServiceProvider.createScope`
     + ++/
    Scoped
}

private mixin template ServiceLifetimeFunctions(ServiceLifetime Lifetime)
{
    import std.conv : to;
    enum Suffix = Lifetime.to!string; // I *wish* this could be `const` instead of `enum`, but it produces a weird `cannot modify struct because immutable members` error.

    @safe nothrow pure
    public static
    {
        ///
        ServiceInfo asRuntime(TypeInfo baseType, TypeInfo implType, FactoryFunc factory = null)
        {
            return ServiceInfo(baseType, implType, factory, Lifetime);
        }

        ///
        ServiceInfo asTemplated(alias BaseType, alias ImplType)(FactoryFuncFor!ImplType factory = null)
        if(isValidBaseType!BaseType && isValidImplType!(BaseType, ImplType))
        {
            if(factory is null)
                factory = (ref services) => Injector.construct!ImplType(services);

            return ServiceInfo(typeid(BaseType), typeid(ImplType), factory, Lifetime);
        }

        ///
        mixin("alias as"~Suffix~"Runtime = asRuntime;");

        ///
        mixin("alias as"~Suffix~"(alias BaseType, alias ImplType) = asTemplated!(BaseType, ImplType);");

        ///
        mixin("alias as"~Suffix~"(alias ImplType) = asTemplated!(ImplType, ImplType);");
    }
}

/++
 + Describes a service.
 +
 + This struct shouldn't be created directly, you must use one of the static construction functions.
 +
 + For example, if you wanted the service to be a singleton, you could do `asSingleton!(IBaseType, ImplementationType)`.
 + ++/
struct ServiceInfo
{
    alias FactoryFunc               = Object delegate(ref ServiceScope);
    alias FactoryFuncFor(T)         = T delegate(ref ServiceScope);
    enum  isValidBaseType(T)        = (is(T == class) || is(T == interface));
    enum  isValidImplType(BaseT, T) = (is(T == class) && (is(T : BaseT) || is(T == BaseT)));
    enum  isValidImplType(T)        = isValidImplType!(T, T);

    private
    {
        TypeInfo        _baseType;
        TypeInfo        _implType;
        FactoryFunc     _factory;
        ServiceLifetime _lifetime;

        @safe @nogc
        this(TypeInfo baseType, TypeInfo implType, FactoryFunc func, ServiceLifetime lifetime) nothrow pure
        {
            this._baseType = baseType;
            this._implType = implType;
            this._factory  = func;
            this._lifetime = lifetime;

            assert(func !is null, "The factory function is null. The `asXXXRuntime` functions can't auto-generate one sadly, so provide your own.");
        }
    }

    /// This is mostly for unit tests.
    @safe
    bool opEquals(const ServiceInfo rhs) const pure nothrow
    {
        return 
        (
            this._baseType is rhs._baseType
         && this._implType is rhs._implType
         && this._lifetime == rhs._lifetime
        );
    }

    /// So we can use this struct as an AA key more easily
    @trusted // @trusted since we're only converting a pointer to a number, without doing anything else to it. 
    size_t toHash() const pure nothrow
    {
        const baseTypePointer  = cast(size_t)(cast(void*)this._baseType);
        const implTypePointer  = cast(size_t)(cast(void*)this._implType);
        const lifetimeAsNumber = cast(size_t)this._lifetime;

        // NOTE: This is just something completely random I made up. I'll research into a proper technique eventually, this just has to exist *in some form* for now.
        return (baseTypePointer ^ implTypePointer) * lifetimeAsNumber;
    }

    mixin ServiceLifetimeFunctions!(ServiceLifetime.Singleton);
    mixin ServiceLifetimeFunctions!(ServiceLifetime.Transient);
    mixin ServiceLifetimeFunctions!(ServiceLifetime.Scoped);
}
///
@safe nothrow pure
unittest
{
    static interface I {}
    static class C : I {}

    Object dummyFactory(ref ServiceScope){ return null; }

    // Testing: All 3 aliases can be found, 1 alias per lifetime, which also tests that all lifetimes are handled properly.
    assert(
        ServiceInfo.asSingletonRuntime(typeid(I), typeid(C), &dummyFactory)
        ==
        ServiceInfo(typeid(I), typeid(C), &dummyFactory, ServiceLifetime.Singleton)
    );

    assert(
        ServiceInfo.asTransient!(I, C)((ref provider) => new C())
        ==
        ServiceInfo(typeid(I), typeid(C), &dummyFactory, ServiceLifetime.Transient) // NOTE: Factory func is ignored in opEquals, so `dummyFactory` here is fine.
    );

    assert(
        ServiceInfo.asScoped!C()
        ==
        ServiceInfo(typeid(C), typeid(C), &dummyFactory, ServiceLifetime.Scoped)
    );
}

struct ServiceScope
{
    private size_t          _index;
    private ServiceProvider _provider;
    private bool            _isMasterReference; // True = Scope is destroyed via this object. False = Scope can't be destroyed via this object.

    @disable
    this(this);

    ~this()
    {
        if(this._provider !is null && this._isMasterReference)
            this._provider.destroyScope(this);
    }

    Object getServiceOrNull(TypeInfo baseType)
    {
        return this._provider.getServiceOrNull(baseType, this);
    }

    T getServiceOrNull(alias T)()
    if(ServiceInfo.isValidBaseType!T)
    {
        auto service = this.getServiceOrNull(typeid(T));
        if(service is null)
            return null;

        auto casted = cast(T)service;
        assert(casted !is null, "Invalid cast.");

        return casted;
    }
    ///
    unittest
    {
        static interface IPrime
        {
            int getPrime();
        }

        static class PrimeThree : IPrime
        {
            int getPrime()
            {
                return 3;
            }
        }

        auto services = new ServiceProvider([ServiceInfo.asTransient!(IPrime, PrimeThree)]);
        auto service = services.defaultScope.getServiceOrNull!IPrime();
        assert(service !is null);
        assert(service.getPrime() == 3);
    }
}

final class ServiceScopeAccessor
{
    // Since ServiceScope can't be copied, and we shouldn't exactly move it from it's default location, we need to re-store
    // some of its info for later.
    private ServiceProvider _provider; 
    private size_t          _index;

    private this(ref ServiceScope serviceScope)
    {
        this._provider = serviceScope._provider;
        this._index    = serviceScope._index;
    }

    final ServiceScope serviceScope()
    {
        return ServiceScope(this._index, this._provider, false); // false = Not master scope object.
    }
}

final class ServiceProvider
{
    import std.typecons : Nullable, nullable;

    alias ServiceInstanceDictionary = Object[ServiceInfo];
    enum BITS_PER_MASK = long.sizeof * 8;

    private
    {
        struct ScopeInfo
        {
            ServiceInstanceDictionary instances;
            ServiceScopeAccessor      accessor; // Written in a way that they only have to be constructed once, so GC isn't as mad.
        }

        ServiceScope                _defaultScope;
        ServiceInfo[]               _allServices;
        ScopeInfo[]                 _scopes;
        ServiceInstanceDictionary   _singletons;
        long[]                      _scopeInUseMasks;

        Object getServiceOrNull(TypeInfo baseType, ref scope ServiceScope serviceScope)
        {
            assert(serviceScope._provider is this, "Attempting to use service scope who does not belong to this `ServiceProvider`.");

            auto infoNullable = this.getServiceInfoForBaseType(baseType);
            if(infoNullable.isNull)
                return null;

            auto info = infoNullable.get();
            final switch(info._lifetime) with(ServiceLifetime)
            {
                case Transient:
                    return info._factory(serviceScope);

                case Scoped:
                    auto ptr = (cast()info in this._scopes[serviceScope._index].instances); // 'cus apparently const is too painful for it to handle.
                    if(ptr !is null)
                        return *ptr;

                    auto instance = info._factory(serviceScope);
                    this._scopes[serviceScope._index].instances[cast()info] = instance;
                    return instance;

                case Singleton:
                    // TODO: Functionise this
                    auto ptr = (cast()info in this._singletons); // 'cus apparently const is too painful for it to handle.
                    if(ptr !is null)
                        return *ptr;

                    auto instance = info._factory(serviceScope);
                    this._singletons[cast()info] = instance;
                    return instance;
            }
        }

        @safe
        ref long getScopeMaskByScopeIndex(size_t index) nothrow
        {
            const indexIntoArray = (index / BITS_PER_MASK);

            if(indexIntoArray >= this._scopeInUseMasks.length)
                this._scopeInUseMasks.length = indexIntoArray + 1;

            return this._scopeInUseMasks[indexIntoArray];
        }

        @safe
        bool isScopeInUse(size_t index) nothrow
        {
            const bitInMask = (index % BITS_PER_MASK);
            const mask      = this.getScopeMaskByScopeIndex(index);

            return (mask & (1 << bitInMask)) > 0;
        }

        @safe
        void setScopeInUse(size_t index, bool isInUse) nothrow
        {
            const bitInMask = (index % BITS_PER_MASK);
            const bitToUse  = (1 << bitInMask);

            if(isInUse)
                this.getScopeMaskByScopeIndex(index) |= bitToUse;
            else
                this.getScopeMaskByScopeIndex(index) &= ~bitToUse;
        }
        ///
        unittest
        {
            auto services = new ServiceProvider(null);
            assert(!services.isScopeInUse(65));

            services.setScopeInUse(65, true);
            assert(services.isScopeInUse(65));
            assert(services._scopeInUseMasks.length == 2);
            assert(services._scopeInUseMasks[1] == 0b10); // 65 % 64 = 1. 1 << 1 = 0b10
            
            services.setScopeInUse(65, false);
            assert(!services.isScopeInUse(65));
        }
    }

    this(ServiceInfo[] services)
    {
        this._defaultScope = this.createScope();

        // I'm doing it this weird way to try and make the GC less angry.
        const EXTRA_SERVICES = 2;
        this._allServices.length                = services.length + EXTRA_SERVICES;
        this._allServices[0..services.length]   = services[0..$];
        this._allServices[services.length]      = ServiceInfo.asSingleton!ServiceProvider((ref _) => this); // Allow ServiceProvider to be injected.
        this._allServices[services.length + 1]  = ServiceInfo.asScoped!ServiceScopeAccessor((ref serviceScope) // Add service to allowed services to access their scope's... scope.
        {
            auto instance = this._scopes[serviceScope._index].accessor;
            if(instance !is null)
                return instance;

            instance = new ServiceScopeAccessor(serviceScope);
            this._scopes[serviceScope._index].accessor = instance;

            return instance;            
        });
    }

    public final
    {
        @safe
        ServiceScope createScope()
        {
            size_t index = 0;
            foreach(i; 0..ulong.sizeof * 8)
            {
                if(!this.isScopeInUse(i))
                {
                    index = i;
                    this.setScopeInUse(i, true);
                    break;
                }
            }

            if(this._scopes.length <= index)
                this._scopes.length = (index + 1);

            return ServiceScope(index, this, true);
        }
        ///
        unittest
        {
            import std.format : format;

            // Basic test to make sure the "in use" mask works properly.
            auto provider = new ServiceProvider(null);

            ServiceScope[3] scopes;
            foreach(i; 0..scopes.length)
            {
                scopes[i] = provider.createScope();
                assert(scopes[i]._index == i + 1, format("%s", scopes[i]._index));
            }

            provider.destroyScope(scopes[1]); // Index 2
            assert(scopes[1]._index == 0);
            assert(scopes[1]._provider is null);
            assert(provider._scopeInUseMasks[0] == 0b1011);

            scopes[1] = provider.createScope();
            assert(scopes[1]._index == 2);
            assert(provider._scopeInUseMasks[0] == 0b1111);
        }

        void destroyScope(ref scope ServiceScope serviceScope)
        {
            assert(serviceScope._provider is this, "Attempting to destroy service scope who does not belong to this `ServiceProvider`.");
            assert(this.isScopeInUse(serviceScope._index), "Bug?");
            assert(serviceScope._isMasterReference, "Attempting to destroy service scope who is not the master reference for the scope. (Did this ServiceScope come from ServiceScopeAccessor?)");

            // For now, just clear the AA. Later on I'll want to add more behaviour though.
            this.setScopeInUse(serviceScope._index, false);
            this._scopes[serviceScope._index].instances.clear();

            serviceScope._index = 0;
            serviceScope._provider = null;
        }

        @safe
        Nullable!(const(ServiceInfo)) getServiceInfoForBaseType(TypeInfo baseType) const nothrow pure
        {
            foreach(service; this._allServices)
            {
                if(service._baseType is baseType)
                    return nullable(service);
            }

            return typeof(return).init;
        }

        Nullable!(const(ServiceInfo)) getServiceInfoForBaseType(alias BaseType)() const
        if(ServiceInfo.isValidBaseType!BaseType)
        {
            return this.getServiceInfoForBaseType(typeid(BaseType));
        }
        ///
        unittest
        {
            static class C {}

            auto info = ServiceInfo.asScoped!C();
            const provider = new ServiceProvider([info]);

            assert(provider.getServiceInfoForBaseType!C() == info);
        }

        @property @safe @nogc
        ref ServiceScope defaultScope() nothrow pure
        {
            return this._defaultScope;
        }
    }
}

static final class Injector
{
    import std.traits : ReturnType, isSomeFunction;

    public static final
    {
        ReturnType!F execute(F)(ref ServiceScope services, F func)
        if(isSomeFunction!F)
        {
            import std.traits : Parameters;

            alias FuncParams = Parameters!F;
            FuncParams params;

            static foreach(i, ParamT; FuncParams)
            {{
                static if(is(ParamT == class) || is(ParamT == interface))
                    params[i] = services.getServiceOrNull!ParamT;
            }}

            static if(is(ReturnType!F == void))
                func(params);
            else
                return func(params);
        }
        ///
        unittest
        {
            static class AandB
            {
                int a = 1;
                int b = 3;
            }

            static int addAandB(AandB ab)
            {
                return ab.a + ab.b;
            }

            auto services = new ServiceProvider([ServiceInfo.asSingleton!AandB]);
            
            assert(Injector.execute(services.defaultScope, &addAandB) == 4);
        }

        T construct(alias T)(ref ServiceScope services)
        if(is(T == class) || is(T == struct))
        {
            import std.traits : Parameters;

            static if(__traits(hasMember, T, "__ctor"))
            {
                alias CtorParams = Parameters!(__traits(getMember, T, "__ctor"));

                static if(is(T == class))
                    return Injector.execute(services, (CtorParams params) => new T(params));
                else
                    return Injector.execute(services, (CtorParams params) => T(params));
            }
            else static if(__traits(hasMember, T, "injectionCtor"))
            {
                alias CtorParams = Parameters!(__traits(getMember, T, "injectionCtor"));
                return Injector.execute(services, (CtorParams params) => T.injectionCtor(params));
            }
            else
            {
                static if(is(T == class))
                    return new T();
                else
                    return T.init;
            }
        }
    }
}

// Testing transient services
unittest
{
    static class Transient
    {
        int increment = 0;

        int getI()
        {
            return this.increment++;
        }
    }

    auto services = new ServiceProvider([ServiceInfo.asTransient!Transient]);
    
    auto serviceA = services.defaultScope.getServiceOrNull!Transient();
    auto serviceB = services.defaultScope.getServiceOrNull!Transient();

    assert(serviceA.getI() == 0);
    assert(serviceA.getI() == 1);
    assert(serviceB.getI() == 0);
}

// Testing scoped services
unittest
{
    static class Scoped
    {
        int increment = 0;

        int getI()
        {
            return this.increment++;
        }
    }

    auto services = new ServiceProvider([ServiceInfo.asScoped!Scoped]);
    auto scopeB   = services.createScope();

    auto serviceA1 = services.defaultScope.getServiceOrNull!Scoped();
    auto serviceA2 = services.defaultScope.getServiceOrNull!Scoped(); // So I can test that it's using the same one.
    auto serviceB  = scopeB.getServiceOrNull!Scoped();
    
    assert(serviceA1 is serviceA2, "Scoped didn't work ;(");
    assert(serviceA1.getI() == 0);
    assert(serviceA2.getI() == 1);
    assert(serviceB.getI() == 0);

    services.destroyScope(scopeB);

    scopeB   = services.createScope();
    serviceB = scopeB.getServiceOrNull!Scoped();
    assert(serviceB.getI() == 0);
}

// Testing singleton services
unittest
{
    static class Singleton
    {
        int increment = 0;

        int getI()
        {
            return this.increment++;
        }
    }

    auto services = new ServiceProvider([ServiceInfo.asSingleton!Singleton]);
    auto scopeB   = services.createScope();

    auto serviceA = services.defaultScope.getServiceOrNull!Singleton;
    auto serviceB = scopeB.getServiceOrNull!Singleton;

    assert(serviceA !is null && serviceA is serviceB);
    assert(serviceA.getI() == 0);
    assert(serviceB.getI() == 1);
}

// Testing scope dtor behaviour
unittest
{
    auto services = new ServiceProvider(null);
    auto scopeB = services.createScope();
    assert(scopeB._index == 1);

    // Test #1, seeing if setting a new value for a scope variable performs the dtor properly.
    {
        scopeB = services.createScope();
        assert(scopeB._index == 2);
        assert(services._scopeInUseMasks[0] == 0b101);
    }

    services.destroyScope(scopeB);

    // Test #2, seeing if going out of scope uses the dtor properly (it should if the first case works, but may as well add a test anyway :P)
    {
        auto scopedScope = services.createScope();
        assert(scopedScope._index == 1);

        scopeB = services.createScope();
        assert(scopeB._index == 2);
    }

    assert(services._scopeInUseMasks[0] == 0b101);
    scopeB = services.createScope();
    assert(scopeB._index == 1);
    assert(services._scopeInUseMasks[0] == 0b11);
}

// Test ServiceProvider injection
unittest
{
    auto services = new ServiceProvider(null);

    assert(services.defaultScope.getServiceOrNull!ServiceProvider() is services);
}

// Test ServiceScopeAccessor
unittest
{
    auto services = new ServiceProvider(null);
    
    // Also test to make sure the slaveScope doesn't destroy the scope outright.
    {
        const slaveScope = services.defaultScope.getServiceOrNull!ServiceScopeAccessor().serviceScope;
        assert(slaveScope._provider is services);
        assert(slaveScope._index == 0);
        assert(!slaveScope._isMasterReference);
    }
    assert(services._scopeInUseMasks[0] == 0b1);

    // Test to make sure we only construct the accessor a single time per scope index.
    auto masterScope = services.createScope();
    assert(services._scopes[1].accessor is null);
    assert(masterScope.getServiceOrNull!ServiceScopeAccessor() !is null);
    assert(services._scopes[1].accessor !is null);

    auto accessor = masterScope.getServiceOrNull!ServiceScopeAccessor();
    services.destroyScope(masterScope);
    masterScope = services.createScope();
    assert(services._scopes[1].accessor is accessor);
}