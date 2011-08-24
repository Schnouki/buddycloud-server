async = require('async')
RSM = require('./xmpp/rsm')
NS = require('./xmpp/ns')
rsmWalk = require('./rsm_walk')

class Synchronization
    constructor: (@router, @node) ->
        @request = {
            operation: => @operation
            node: @node
            dontCache: true
        }

    run: (t, cb) ->
        @runRequest (err, results) =>
            if err
                return cb err

            @reset t, (err) =>
                if err
                    return cb err

                @writeResults t, results, cb

    runRequest: (cb) ->
        @router.runRemotely @request, cb


class ConfigSynchronization extends Synchronization
    operation: 'browse-node-info'

    reset: (t, cb) ->
        t.resetConfig(@node, cb)

    writeResults: (t, results, cb) ->
        console.log 'configResults': results
        if results.config
            t.setConfig(@node, results.config, cb)
        else
            cb(new Error("No pubsub meta data form found"))

##
# Walks items with RSM
class PaginatedSynchronization extends Synchronization
    constructor: ->
        super
        @request.rsm = new RSM.RSM()

    run: (t, cb) ->
        rsmWalk (offset, cb2) ->
            console.log "walk", offset
            @request.rsm.after = offset
            @runRequest (err, results) =>
                console.log "ranRequest", err, results
                if err
                    return cb2 err

                go = (err) =>
                    if err
                        return cb2 err

                    @writeResults t, results, (err) =>
                        if err
                            return cb2 results

                        nextOffset = results.rsm?.last
                        cb2 null, nextOffset

                # reset() only after 1st successful result
                unless @resetted  # (excuse my grammar)
                    @resetted = true
                    @reset t, go
                else
                    go()
        , cb

class ItemsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetItems(@node, cb)

    operation: 'retrieve-node-items'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            # TODO: author?
            t.writeItem @node, item.id, null, item.el, cb2
        , cb

class SubscriptionsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetSubscriptions @node, (err, @userListeners) =>
            cb err

    operation: 'retrieve-node-subscriptions'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            listener = @userListeners[item.user]
            t.setSubscription @node, item.user, listener, item.subscription, cb2
        , cb

class AffiliationsSynchronization extends PaginatedSynchronization
    reset: (t, cb) ->
        t.resetAffiliations(@node, cb)

    operation: 'retrieve-node-affiliations'

    writeResults: (t, results, cb) ->
        async.forEach results, (item, cb2) =>
            t.setAffiliation @node, item.user, item.affiliations, cb2
        , cb


# TODO: move queueing here
exports.syncNode = (router, model, node, cb) ->
    console.log "syncNode #{node}"
    async.forEachSeries [
        ConfigSynchronization, ItemsSynchronization,
        SubscriptionsSynchronization, AffiliationsSynchronization
    ]
    , (syncClass, cb2) ->
        synchronization = new syncClass(router, node)
        model.transaction (err, t) ->
            if err
                console.error err.stack or err
                return cb2 err

            synchronization.run t, (err) ->
                if err
                    console.error err.stack or err
                    t.rollback ->
                        cb2 err
                    return

                t.commit (err) ->
                    if err
                        return cb2 err

                    cb2()
    , cb

exports.syncServer = (router, model, server, cb) ->
    opts =
        operation: -> 'retrieve-user-subscriptions'
        jid: server
    opts.rsm = new RSM.RSM()
    rsmWalk (nextOffset, cb2) ->
        opts.rsm.after = nextOffset
        router.runRemotely opts, (err, results) ->
            if err
                return cb2 err

            async.forEach results, (subscription, cb3) ->
                unless subscription.node
                    # Weird, skip;
                    cb3()

                user = getNodeUser(subscription.node)
                unless user
                    # Weird, skip;
                    cb3()

                router.authorizeFor user, server, (err, valid) ->
                    if err or !valid
                        console.error(err.stack or err or
                            "Cannot sync #{subscription.node} from unauthorized server #{server}"
                        )
                        cb3()
                    else
                        exports.syncNode router, model, subscription.node, (err) ->
                            # Ignore err, a single node may fail
                            cb3()
            , cb2
    , cb

nodeRegexp = /^\/user\/([^\/]+)\/?(.*)/
getNodeUser = (node) ->
    unless node
        return null

    m = nodeRegexp.exec(node)
    unless m
        return null

    m[1]
