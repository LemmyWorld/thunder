import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:lemmy_api_client/v3.dart';

import 'package:thunder/community/bloc/anonymous_subscriptions_bloc.dart';
import 'package:thunder/community/bloc/community_bloc.dart';
import 'package:thunder/community/enums/community_action.dart';
import 'package:thunder/community/widgets/community_header.dart';
import 'package:thunder/core/auth/bloc/auth_bloc.dart';
import 'package:thunder/feed/bloc/feed_bloc.dart';
import 'package:thunder/feed/utils/utils.dart';
import 'package:thunder/feed/view/feed_page.dart';
import 'package:thunder/shared/snackbar.dart';
import 'package:thunder/shared/sort_picker.dart';
import 'package:thunder/thunder/bloc/thunder_bloc.dart';
import 'package:thunder/user/widgets/user_header.dart';

class FeedPageAppBar extends StatelessWidget {
  const FeedPageAppBar({
    super.key,
    required this.tabController,
    this.showAppBarTitle = true,
    this.showSidebar = false,
    this.onHeaderTapped,
    required this.innerBoxIsScrolled,
  });

  final TabController tabController;

  final bool showAppBarTitle;
  final bool showSidebar;
  final bool innerBoxIsScrolled;
  final Function(bool)? onHeaderTapped;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    final ThunderBloc thunderBloc = context.read<ThunderBloc>();
    final FeedBloc feedBloc = context.watch<FeedBloc>();
    final FeedState feedState = feedBloc.state;

    final List<String> tabs = <String>['Posts', 'Comments'];

    return SliverAppBar(
      title: FeedAppBarTitle(visible: showAppBarTitle),
      pinned: true,
      centerTitle: false,
      toolbarHeight: 70.0,
      expandedHeight: feedState.feedType != FeedType.general ? (240.0 - (feedState.feedType == FeedType.community ? kTextTabBarHeight : 0)) : null,
      forceElevated: innerBoxIsScrolled,
      leading: feedState.status != FeedStatus.initial
          ? IconButton(
              icon: Navigator.of(context).canPop() && feedBloc.state.feedType != FeedType.general
                  ? (Platform.isIOS
                      ? Icon(
                          Icons.arrow_back_ios_new_rounded,
                          semanticLabel: MaterialLocalizations.of(context).backButtonTooltip,
                        )
                      : Icon(Icons.arrow_back_rounded, semanticLabel: MaterialLocalizations.of(context).backButtonTooltip))
                  : Icon(Icons.menu, semanticLabel: MaterialLocalizations.of(context).openAppDrawerTooltip),
              onPressed: () {
                HapticFeedback.mediumImpact();
                (Navigator.of(context).canPop() && feedBloc.state.feedType != FeedType.general) ? Navigator.of(context).maybePop() : Scaffold.of(context).openDrawer();
              },
            )
          : Container(),
      actions: [
        if (feedState.feedType == FeedType.community)
          BlocListener<CommunityBloc, CommunityState>(
            listener: (context, state) {
              if (state.status == CommunityStatus.success && state.communityView != null) {
                feedBloc.add(FeedCommunityViewUpdatedEvent(communityView: state.communityView!));
              }
            },
            child: IconButton(
              icon: Icon(
                  switch (_getSubscriptionStatus(context)) {
                    SubscribedType.notSubscribed => Icons.add_circle_outline_rounded,
                    SubscribedType.pending => Icons.pending_outlined,
                    SubscribedType.subscribed => Icons.remove_circle_outline_rounded,
                    _ => Icons.add_circle_outline_rounded,
                  },
                  semanticLabel: (_getSubscriptionStatus(context) == SubscribedType.notSubscribed) ? AppLocalizations.of(context)!.subscribe : AppLocalizations.of(context)!.unsubscribe),
              tooltip: switch (_getSubscriptionStatus(context)) {
                SubscribedType.notSubscribed => AppLocalizations.of(context)!.subscribe,
                SubscribedType.pending => AppLocalizations.of(context)!.unsubscribePending,
                SubscribedType.subscribed => AppLocalizations.of(context)!.unsubscribe,
                _ => null,
              },
              onPressed: () {
                if (thunderBloc.state.isFabOpen) thunderBloc.add(const OnFabToggle(false));

                HapticFeedback.mediumImpact();
                _onSubscribeIconPressed(context);
              },
            ),
          ),
        IconButton(
            onPressed: () {
              HapticFeedback.mediumImpact();
              triggerRefresh(context);
            },
            icon: Icon(Icons.refresh_rounded, semanticLabel: l10n.refresh)),
        Container(
          margin: const EdgeInsets.only(right: 8.0),
          child: IconButton(
            icon: Icon(Icons.sort, semanticLabel: l10n.sortBy),
            onPressed: () {
              HapticFeedback.mediumImpact();

              showModalBottomSheet<void>(
                showDragHandle: true,
                context: context,
                isScrollControlled: true,
                builder: (builderContext) => SortPicker(
                  title: l10n.sortOptions,
                  onSelect: (selected) => feedBloc.add(FeedChangeSortTypeEvent(selected.payload)),
                  previouslySelected: feedBloc.state.sortType,
                ),
              );
            },
          ),
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        expandedTitleScale: 1,
        collapseMode: CollapseMode.none,
        background: (feedState.getPersonDetailsResponse != null || feedState.fullCommunityView != null)
            ? Padding(
                padding: EdgeInsets.only(top: 110.0, bottom: feedState.feedType == FeedType.user ? kTextTabBarHeight : 0),
                child: AnimatedOpacity(
                  opacity: showAppBarTitle ? 0.0 : 1.0,
                  duration: const Duration(milliseconds: 100),
                  child: Visibility(
                    visible: feedState.feedType == FeedType.user || feedState.feedType == FeedType.community,
                    child: feedState.getPersonDetailsResponse != null
                        ? UserHeader(
                            personView: feedState.getPersonDetailsResponse!.personView,
                            showUserSidebar: showSidebar,
                            onToggle: (bool toggled) => onHeaderTapped?.call(toggled),
                          )
                        : CommunityHeader(
                            getCommunityResponse: feedState.fullCommunityView!,
                            showCommunitySidebar: showSidebar,
                            onToggle: (bool toggled) => onHeaderTapped?.call(toggled),
                          ),
                  ),
                ),
              )
            : null,
      ),
      bottom: (feedState.feedType == FeedType.user)
          ? TabBar(
              controller: tabController,
              tabs: tabs.map((String name) => Tab(text: name)).toList(),
            )
          : null,
    );
  }
}

class FeedAppBarTitle extends StatelessWidget {
  const FeedAppBarTitle({super.key, this.visible = true});

  final bool visible;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final FeedBloc feedBloc = context.watch<FeedBloc>();

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: visible ? 1.0 : 0.0,
      child: ListTile(
        title: Text(
          feedBloc.state.feedType == FeedType.user ? getUserName(feedBloc.state) : getCommunityName(feedBloc.state),
          style: theme.textTheme.titleLarge,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Row(
          children: [
            Icon(getSortIcon(feedBloc.state), size: 13),
            const SizedBox(width: 4),
            Text(getSortName(feedBloc.state)),
          ],
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 0),
      ),
    );
  }
}

/// Get the subscription status for the current user and community
/// The logic works for anonymous accounts and for logged in accounts
SubscribedType? _getSubscriptionStatus(BuildContext context) {
  final AuthBloc authBloc = context.read<AuthBloc>();
  final FeedBloc feedBloc = context.read<FeedBloc>();
  final AnonymousSubscriptionsBloc anonymousSubscriptionsBloc = context.read<AnonymousSubscriptionsBloc>();

  if (authBloc.state.isLoggedIn) {
    return feedBloc.state.fullCommunityView?.communityView.subscribed;
  }

  return anonymousSubscriptionsBloc.state.ids.contains(feedBloc.state.fullCommunityView?.communityView.community.id) ? SubscribedType.subscribed : SubscribedType.notSubscribed;
}

void _onSubscribeIconPressed(BuildContext context) {
  final AuthBloc authBloc = context.read<AuthBloc>();
  final FeedBloc feedBloc = context.read<FeedBloc>();

  final FeedState feedState = feedBloc.state;

  if (authBloc.state.isLoggedIn) {
    context.read<CommunityBloc>().add(
          CommunityActionEvent(
            communityId: feedBloc.state.fullCommunityView!.communityView.community.id,
            communityAction: CommunityAction.follow,
            value: (feedState.fullCommunityView?.communityView.subscribed == SubscribedType.notSubscribed ? true : false),
          ),
        );
    return;
  }

  Community community = feedBloc.state.fullCommunityView!.communityView.community;
  Set<int> currentSubscriptions = context.read<AnonymousSubscriptionsBloc>().state.ids;

  if (currentSubscriptions.contains(community.id)) {
    context.read<AnonymousSubscriptionsBloc>().add(DeleteSubscriptionsEvent(ids: {community.id}));
    showSnackbar(context, AppLocalizations.of(context)!.unsubscribed);
  } else {
    context.read<AnonymousSubscriptionsBloc>().add(AddSubscriptionsEvent(communities: {community}));
    showSnackbar(context, AppLocalizations.of(context)!.subscribed);
  }
}
