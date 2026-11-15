/// The top-level domains the address detector knows without a scheme.
///
/// Only common endings count, so text such as `hello.world` stays a search. Typing `https://` or
/// `www.` opens any address.
nonisolated enum TopLevelDomains {
    /// Endings that are also common file extensions. A bare name with one of these, such as
    /// `README.md` or `Safari.app`, is not an address unless it has `www.`, a port or a path.
    static let ambiguous: Set<String> = words(
        """
        ac am app as cc cl cr cu gd in md mk ml mm mo pl pm ps py re rs sh so tf
        """)

    /// Generic endings people type, and every country code except the ambiguous ones.
    static let common: Set<String> = words(
        """
        com net org edu gov mil int info biz xyz dev page blog cloud online site store shop tech wiki
        design agency studio email systems software network digital tools academy foundation news asia
        museum aero coop jobs travel
        ad ae af ag ai al ao aq ar at au aw ax az ba bb bd be bf bg bh bi bj bm bn bo br bs bt bw by bz
        ca cd cf cg ch ci ck cm cn co cv cw cx cy cz de dj dk dm do dz ec ee eg er es et eu fi fj fk fm
        fo fr ga ge gf gg gh gi gl gm gn gp gq gr gs gt gu gw gy hk hm hn hr ht hu id ie il im io iq ir
        is it je jm jo jp ke kg kh ki km kn kp kr kw ky kz la lb lc li lk lr ls lt lu lv ly ma mc me mg
        mh mn mp mq mr ms mt mu mv mw mx my mz na nc ne nf ng ni nl no np nr nu nz om pa pe pf pg ph pk
        pn pr pt pw qa ro ru rw sa sb sc sd se sg si sk sl sm sn sr ss st su sv sx sy sz tc td tg th tj
        tk tl tm tn to tr tt tv tw tz ua ug uk us uy uz va vc ve vg vi vn vu wf ws ye yt za zm zw
        """)

    private static func words(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isWhitespace).map(String.init))
    }
}
