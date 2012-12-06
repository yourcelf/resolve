#= require ../intertwinkles/js/intertwinkles/index

intertwinkles.build_toolbar($("header"), {applabel: "resolve"})
intertwinkles.build_footer($("footer"))

resolve = {}

class Proposal extends Backbone.Model
  idAttribute: "_id"
class ProposalCollection extends Backbone.Collection
  model: Proposal
  comparator: (p) ->
    return new Date(p.get("revisions")[0].date).getTime()

resolve.model = new Proposal()

if INITIAL_DATA.proposal?
  resolve.model.set(INITIAL_DATA.proposal)

handle_error = (data) ->
  flash "error", "Oh golly, but the server has errored. So sorry."
  console.info(data)

class BaseView extends Backbone.View
  softNav: (event) =>
    event.preventDefault()
    resolve.app.navigate($(event.currentTarget).attr("href"), {
      trigger: true
    })
  initialize: ->
    @views = []

  remove: =>
    if @views?
      view.remove() for view in @views
    super()

  addView: (selector, view) =>
    @$(selector).html(view.el)
    view.render()
    @views.push(view)

  validateFields: (container, selectors) =>
    cleaned_data = {}
    dirty = false
    $(".error", container).removeClass("error")
    $(".error-msg", container).remove()
    for [selector, test, msg] in selectors
      el = @$(selector)
      if el.attr("type") == "checkbox"
        val = el.is(":checked")
      else
        val = el.val()

      clean = test(val)
      if clean?
        cleaned_data[el.attr("name")] = clean
      else
        dirty = true
        parent = el.closest(".control-group")
        parent.addClass("error")
        parent.find(".controls").prepend(
          "<span class='error-msg help-inline'>#{msg}</span>"
        )
    if dirty
      return false
    return cleaned_data

BaseEvents = {
  'click .softnav': 'softNav'
}

class SplashView extends BaseView
  template: _.template($("#splashTemplate").html())
  itemTemplate: _.template($("#listedProposalTemplate").html())
  events: _.extend {
  }, BaseEvents
  
  initialize: ->
    intertwinkles.user.on "change", @getProposalList
    super()

  remove: =>
    intertwinkles.user.off "change", @getProposalList
    super()

  render: =>
    @$el.html(@template())

  getProposalList: =>
    intertwinkles.socket.on "list_proposals", (data) =>
      if data.error?
        flash "error", "The server. It has got confused."
        console.info(data.error)

class AddProposalView extends BaseView
  template: _.template($("#addProposalTemplate").html())
  events: _.extend {
    'submit   form': 'saveProposal'
  }, BaseEvents

  initialize: ->
    intertwinkles.user.on("change", @onUserChange)
    super()

  remove: =>
    intertwinkles.user.off("change", @onUserChange)
    super()

  onUserChange: =>
    val = @$("textarea").val()
    @render()
    @$("textarea").val(val)

  render: =>
    @$el.html(@template())
    @sharing = new intertwinkles.SharingFormControl()
    @addView(".group-choice", @sharing)

  saveProposal: (event) =>
    event.preventDefault()
    # Validate fields.
    cleaned_data = @validateFields "form", [
      ["#id_proposal", ((val) -> val or null), "This field is required."]
      ["#id_name", (val) ->
        if $("#id_user_id").val() or val
          return val or ""
        return null
      , "Please add a name here, or sign in."]
    ]
    if cleaned_data == false
      return
    
    # Upload form. 
    cleaned_data['sharing'] = @sharing.sharing
    callback = "proposal_saved"

    intertwinkles.socket.once callback, (data) =>
      return handle_error(data) if data.error?
      @$("[type=submit]").removeClass("loading").attr("disabled", false)
      resolve.model.set(data.proposal)
      resolve.app.navigate "/p/#{data.proposal._id}/", trigger: true

    @$("[type=submit]").addClass("loading").attr("disabled", true)
    intertwinkles.socket.emit "save_proposal", {
      callback: callback,
      proposal: cleaned_data
      action: "create"
    }

class ShowProposalView extends BaseView
  template: _.template($("#showProposalTemplate").html())
  opinionTemplate: _.template($("#opinionTemplate").html())
  talliesTemplate: _.template($("#talliesTemplate").html())
  events: _.extend {
    'click  .respond-link': 'showResponseForm'
    'submit form.weigh-in': 'saveResponse'
  }, BaseEvents
  votes: {
    yes: "Strongly approve"
    weak_yes: "Approve with reservations"
    discuss: "Need more discussion"
    no: "Have concerns"
    block: "Block"
    abstain: "I have a conflict of interest"
  }

  initialize: (options) ->
    super()
    @vote_order = ([v, @votes[v]] for v in ["yes", "weak_yes", "discuss", "no", "block", "abstain"])

    resolve.model.on "change", @proposalChanged, this
    intertwinkles.user.on "change", =>
      @renderProposal()
      @renderOpinions()
    , this
    intertwinkles.socket.on "proposal_change", @onProposalData

  remove: =>
    intertwinkles.socket.removeAllListeners("proposal_change")
    resolve.model.off(null, null, this)
    intertwinkles.user.off(null, null, this)
    super()

  onProposalData: (data) =>
    resolve.model.set(data.proposal)

  proposalChanged: =>
    changes = resolve.model.changedAttributes()
    if changes.revisions? or changes.resolved? or changes.revisions? or changes.sharing?
      @renderProposal()
    if changes.opinions?
      @renderOpinions()

  render: =>
    @$el.html @template({
      vote_order: @vote_order
    })
    @addView ".room-users", new intertwinkles.RoomUsersMenu(room: resolve.model.id)

    sharingButton = new intertwinkles.SharingSettingsButton(model: resolve.model)
    # Handle changes to sharing settings.
    sharingButton.on "save", (sharing_settings) =>
      intertwinkles.socket.once "proposal_saved", (data) =>
        resolve.model.set(data.proposal)
        sharingButton.close()
      intertwinkles.socket.emit "save_proposal", {
        action: "update"
        proposal: _.extend(resolve.model.toJSON(), {sharing: sharing_settings})
        callback: "proposal_saved"
      }
    @addView ".sharing", sharingButton

    @renderProposal()
    @renderOpinions()

  renderProposal: =>
    rev = resolve.model.get("revisions")[0]
    @$(".proposal .text").html(intertwinkles.markup(rev.text))
    @$(".proposal .editors").html("by " + (
      @_renderUser(r.user_id, r.name) for r in resolve.model.get("revisions")
    ).join(", "))
    @addView ".proposal .date", new intertwinkles.AutoUpdatingDate(rev.date)
    @userChoice = new intertwinkles.UserChoice()
    @addView(".edit-response-modal .name-input", @userChoice)

  renderOpinions: =>
    if intertwinkles.is_authenticated() and intertwinkles.can_edit(resolve.model)
      ownOpinion = _.find resolve.model.get("opinions"), (o) ->
        o.user_id == intertwinkles.user.id
      if not ownOpinion
        @$(".needed").show()
      else
        @$(".respond-link").removeClass("btn-primary").html("Change vote")

    @_renderedOpinions or= {}
    @_opinionRevs or= {}
    for opinion in resolve.model.get("opinions")
      is_non_voting = (
        resolve.model.get("sharing").group_id? and
        intertwinkles.is_authenticated() and
        intertwinkles.groups[resolve.model.get("sharing").group_id]? and
        not _.find(
          intertwinkles.groups[resolve.model.get("sharing").group_id].members,
          (m) -> m.user == opinion.user_id
        )?.voting

      )
      rendered = $(@opinionTemplate({
        _id: opinion._id
        rendered_user: @_renderUser(opinion.user_id, opinion.name)
        vote_value: opinion.revisions[0].vote
        vote_display: @votes[opinion.revisions[0].vote]
        rendered_text: intertwinkles.markup(opinion.revisions[0].text)
        is_non_voting: if is_non_voting then true else false
        stale: (
          new Date(opinion.revisions[0].date) <
          new Date(resolve.model.get("revisions")[0].date)
        )
      }))
      if not @_renderedOpinions[opinion._id]?
        $(".opinions").prepend(rendered)
        @_renderedOpinions[opinion._id] = rendered
        $("##{opinion._id}").effect("highlight", {}, 3000)
        @_opinionRevs[opinion._id] = opinion.revisions.length
      else
        @_renderedOpinions[opinion._id].replaceWith(rendered)
        @_renderedOpinions[opinion._id] = rendered
        if @_opinionRevs[opinion._id] != opinion.revisions.length
          $("##{opinion._id}").effect("highlight", {}, 3000)
        @_opinionRevs[opinion._id] = opinion.revisions.length

      @addView("##{opinion._id} .date",
        new intertwinkles.AutoUpdatingDate(opinion.revisions[0].date))

    @renderTallies()

  renderTallies: =>
    by_vote = {}
    total_count = 0
    for opinion in resolve.model.get("opinions")
      by_vote[opinion.revisions[0].vote] or= []
      by_vote[opinion.revisions[0].vote].push(opinion)
      total_count += 1

    # Don't bother counting "non-voting" if it doesn't make sense: e.g. if
    # we're not a member of the owning group and thus can't see whether someone
    # is a voting member or not, or if this proposal is not owned by a group,
    # and thus there's no notion of voting or non-.
    show_non_voting = (
      resolve.model.get("sharing").group_id? and
      intertwinkles.is_authenticated() and
      intertwinkles.groups[resolve.model.get("sharing").group_id]?
    )

    group = intertwinkles.groups?[resolve.model.get("sharing").group_id]
    tallies = []
    for [vote_value, vote_display] in @vote_order
      votes = by_vote[vote_value] or []
      non_voting = []
      stale = []
      current = []
      for opinion in votes
        rendered = @_renderUser(opinion.user_id, opinion.name)
        if show_non_voting and not _.find(group.members, (m) -> m.user == opinion.user_id)?.voting
          non_voting.push(rendered)
        else
          if new Date(opinion.revisions[0].date) < new Date(resolve.model.get("revisions")[0].date)
            stale.push(rendered)
          else
            current.push(rendered)
      count = non_voting.length + stale.length + current.length
      tally = {
        vote_display: vote_display
        className: vote_value
        count: current.length + stale.length + non_voting.length
        counts: [{
          className: vote_value + " current"
          title: "#{current.length} Current vote#{if current.length == 1 then "" else "s"}"
          content: current.join(", ")
          count: current.length
        }, {
          className: vote_value + " stale"
          title: "#{stale.length} Stale vote#{if stale.length == 1 then "" else "s"}"
          content: (
            "<i>The proposal has changed since these people weighed in:</i><br />" +
            stale.join(", ")
          )
          count: stale.length
        }, {
          className: vote_value + " non-voting"
          title: "#{non_voting.length} Non-voting response#{if non_voting.length == 1 then "" else "s"}"
          content: (
            "<i>These people are non-members or are " +
            "identified as non-voting:</i><br />#{non_voting.join(", ")}"
          )
          count: non_voting.length
        }]
      }
      tallies.push(tally)
    if show_non_voting
      # Missing count
      found_user_ids = []
      for opinion in resolve.model.get("opinions")
        if opinion.user_id?
          found_user_ids.push(opinion.user_id)
      missing = _.difference(
        _.map(
          intertwinkles.groups[resolve.model.get("sharing").group_id].members,
          (m) -> m.user
        )
        found_user_ids
      )
      total_count += missing.length
      tally = {
        vote_display: "Haven't voted yet"
        className: "missing"
        count: missing.length
        counts: [{
          className: "missing"
          title: "Haven't voted yet"
          content: "<i>The following people haven't voted yet:</i><br />" + (
            @_renderUser(user_id, "Protected") for user_id in missing
          ).join(", ")
          count: missing.length
        }]
      }
      tallies.push(tally)

    for tally in tallies
      for type in tally.counts
        type.percentage = 100 * type.count / total_count
    @$(".tallies").html(@talliesTemplate({tallies}))
    @$("[rel=popover]").popover()

  showResponseForm: (event) =>
    event.preventDefault()
    opinion_id = $(event.currentTarget).attr("data-id")
    if opinion_id?
      opinion = _.find(resolve.model.get("opinions"), (o) -> o._id == opinion_id)
      rev = opinion[0]
      @$("#id_vote").val(rev.vote)
      @$("#id_text").val(rev.text)
      @userChoice.set(rev.user_id, rev.name)
    else
      @$("#id_vote").val("")
      @$("#id_text").val("")
      @userChoice.set(intertwinkles.user.id, intertwinkles.user.get("name"))

    @$(".edit-response-modal").modal()

  saveResponse: (event) =>
    event.preventDefault()
    cleaned_data = @validateFields "form.weigh-in", [
      ["#id_user_id", ((val) -> val or ""), ""]
      ["#id_user", ((val) -> val or null), "This field is required"]
      ["#id_vote", ((val) -> val or null), "This field is required"]
      ["#id_text", ((val) -> val or null), "This field is required"]
    ]
    return if cleaned_data == false

    @$("form.weigh-in input[type=submit]").addClass("loading").attr("disabled", true)

    intertwinkles.socket.once "save_complete", (data) =>
      @$("form.weigh-in input[type=submit]").removeClass("loading").attr("disabled", false)
      @$(".modal").modal('hide')
      if data.error?
        flash "error", "Oh noes.. There seems to be a server malfunction."
        console.info(data.error)
        return
      @onProposalData(data)

    intertwinkles.socket.emit "save_proposal", {
      callback: "save_complete"
      action: "append"
      proposal: {
        _id: resolve.model.id
      }
      opinion: {
        user_id: cleaned_data.user_id
        name: cleaned_data.name
        vote: cleaned_data.vote
        text: cleaned_data.text
      }
    }

  _renderUser: (user_id, name) ->
    if user_id? and intertwinkles.users?[user_id]?
      user = intertwinkles.users[user_id]
      return "<span class='user'><img src='#{user.icon.tiny}' /> #{user.name}</span>"
    else
      return "<span class='user'><i class='icon-user'></i> #{name}</span>"



class Router extends Backbone.Router
  routes:
    'p/:id/':   'room'
    'new/':        'newProposal'
    '':           'index'

  index: =>
    @_display(new SplashView())

  newProposal: =>
    @_display(new AddProposalView())

  room: (id) =>
    if not resolve.model?.id == id
      intertwinkles.socket.once "load_proposal", (data) ->
        resolve.model.set(data.proposal)
      intertwinkles.socket.emit "get_proposal",
        proposal: {_id: id}
        callback: "load_proposal"

    @_display(new ShowProposalView(id: id))

  _display: (view) =>
    @view?.remove()
    $("#app").html(view.el)
    view.render()
    @view = view


socket = io.connect("/iorooms")
socket.on "error", (data) ->
  flash "error", "Oh noes, server error."
  window.console?.log?(data.error)

socket.on "connect", ->
  intertwinkles.socket = socket
  unless resolve.started == true
    resolve.app = new Router()
    Backbone.history.start(pushState: true)
    resolve.started = true
