xmpp = require('node-xmpp')
async = require('async')
NS = require('./ns')

class PubsubClient
    constructor: (conn) ->
        @conn = conn
        @myJID = conn.jid
        @sendIq = (iq, cb) ->
            conn.sendIq iq, cb

    ##
    # @param {Function} cb(Error, PubsubUser)
    discover: (userId, cb) ->
        jid = new xmpp.JID userId
        @discoItems jid.server, undefined, (error, items) =>
            # TODO: restrict to local database access
            containsOurselves = items.some (item) =>
                item.jid is @myJID

            # check info for all listed JIDs
            firstJID = null
            async.some items, (item, someCb) =>
                # TODO: add short timeout when introducing other
                # protocols for responsiveness
                @discoInfo item.jid, undefined, (error, info) ->
                    return unless info && info.identities

                    # looking for pubsub/channels identity
                    for identity in info.identities
                        if identity.category is 'pubsub' &&
                           identity.type is 'channels'
                            firstJID = item.jid
                            someCb(true)
            , (someChannel) =>
                if someChannel and firstJID?
                    cb null, new PubsubUser(@, userId)
                else
                    cb new errors.NotFound()

    ##
    # XEP-0030 browse for #items
    # @param {Function} cb(error, [{ jid: String, node: String }])
    discoItems: (jid, node, cb) ->
        queryAttrs =
            xmlns: NS.DISCO_ITEMS
        if node?
                queryAttrs.node = node
        @sendIq(
            new xmpp.Element('iq', to: jid, type: 'get').
            c('query', queryAttrs)
        , (error, reply) ->

            if error
                return cb error

            results = []
            queryEl = reply?.getChild('query')
            if queryEl
                results = for itemEl in queryEl.getChildren('item')
                    { jid: itemEl.attr.jid
                      node: itemEl.attr.node }
            cb(null, results)
        )

    ##
    # XEP-0030 disco with #info for <identity/>
    # cb(error, { identities: [{ category: String, type: String }],
    #             features: [String],
    #             forms: [ { type: 'result', fields: { ... } } ]
    #           })
    discoInfo: (jid, node, cb) ->
        queryAttrs =
            xmlns: Strophe.NS.DISCO_INFO
        if node?
                queryAttrs.node = node
        @sendIq(
            new xmpp.Element('iq', to: jid, type: 'get').
            c('query', queryAttrs)
        , (error, reply) ->
            if error
                return cb error

            result =
                identities: []
                features: []
                forms: []
            queryEl = reply?.getChild('query')
            if queryEl
                # Extract identities
                result.identities =
                    for identityEl in queryEl.getChildren('identity')
                        { category: identityEl.attr.category
                          type: identityEl.attr.type }
                # Extract features
                result.features =
                    for featureEl in queryEl.getChildren('feature')
                        featureEl.attr.var
                # Extract forms
                result.forms =
                    for xEl in queryEl.getChildren('x', NS.DATA)
                        form =
                            type: xEl.attrs.type
                            fields: {}
                        for fieldEl in xEl.getChildren('field')
                            key = fieldEl.attrs.var
                            values = []
                            type = fieldEl.attrs.type || 'text-single'
                            for valueEl in fieldEl.getChildren('value')
                                values.push valueEl.getText()
                                form.fields[key] = if /-multi$/.test(type)
                                    values
                                else
                                    values[0]
                        form
            cb null, result
        )

class PubsubNode
    constructor: (client, userId) ->
