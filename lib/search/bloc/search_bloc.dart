import 'package:bloc/bloc.dart';
import 'package:equatable/equatable.dart';
import 'package:bloc_concurrency/bloc_concurrency.dart';
import 'package:lemmy_api_client/v3.dart';
import 'package:stream_transform/stream_transform.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:collection/collection.dart';

import 'package:thunder/account/models/account.dart';
import 'package:thunder/core/auth/helpers/fetch_account.dart';
import 'package:thunder/core/models/post_view_media.dart';
import 'package:thunder/core/singletons/lemmy_client.dart';
import 'package:thunder/feed/utils/community.dart';
import 'package:thunder/post/utils/post.dart';
import 'package:thunder/search/utils/search_utils.dart';
import 'package:thunder/comment/utils/comment.dart';
import 'package:thunder/utils/global_context.dart';
import 'package:thunder/utils/instance.dart';

part 'search_event.dart';
part 'search_state.dart';

const throttleDuration = Duration(milliseconds: 300);
const timeout = Duration(seconds: 10);

EventTransformer<E> throttleDroppable<E>(Duration duration) {
  return (events, mapper) => droppable<E>().call(events.throttle(duration), mapper);
}

class SearchBloc extends Bloc<SearchEvent, SearchState> {
  SearchBloc() : super(SearchState()) {
    on<StartSearchEvent>(
      _startSearchEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ChangeCommunitySubsciptionStatusEvent>(
      _changeCommunitySubsciptionStatusEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ResetSearch>(
      _resetSearch,
      transformer: throttleDroppable(throttleDuration),
    );
    on<ContinueSearchEvent>(
      _continueSearchEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<FocusSearchEvent>(
      _focusSearchEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<GetTrendingCommunitiesEvent>(
      _getTrendingCommunitiesEvent,
      transformer: throttleDroppable(throttleDuration),
    );
    on<VoteCommentEvent>(
      _voteCommentEvent,
      transformer: throttleDroppable(Duration.zero), // Don't give a throttle on vote
    );
    on<SaveCommentEvent>(
      _saveCommentEvent,
      transformer: throttleDroppable(Duration.zero), // Don't give a throttle on save
    );
  }

  Future<void> _resetSearch(ResetSearch event, Emitter<SearchState> emit) async {
    emit(state.copyWith(status: SearchStatus.initial, trendingCommunities: []));
    await _getTrendingCommunitiesEvent(GetTrendingCommunitiesEvent(), emit);
  }

  Future<void> _startSearchEvent(StartSearchEvent event, Emitter<SearchState> emit) async {
    try {
      emit(state.copyWith(status: SearchStatus.loading));

      if (event.query.isEmpty) {
        return emit(state.copyWith(status: SearchStatus.initial));
      }

      Account? account = await fetchActiveProfileAccount();
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      SearchResponse searchResponse = await lemmy.run(Search(
        auth: account?.jwt,
        q: event.query,
        page: 1,
        limit: 15,
        sort: event.sortType,
        listingType: event.listingType,
        type: event.searchType,
        communityId: event.communityId,
        creatorId: event.creatorId,
      ));

      // If there are no search results, see if this is an exact search
      if (event.searchType == SearchType.communities && searchResponse.communities.isEmpty) {
        // Note: We could jump straight to GetCommunity here.
        // However, getLemmyCommunity has a nice instance check that can short-circuit things
        // if the instance is not valid to start.
        String? communityName = await getLemmyCommunity(event.query);
        if (communityName != null) {
          try {
            Account? account = await fetchActiveProfileAccount();

            final getCommunityResponse = await LemmyClient.instance.lemmyApiV3.run(GetCommunity(
              name: communityName,
              auth: account?.jwt,
            ));

            searchResponse = searchResponse.copyWith(communities: [getCommunityResponse.communityView]);
          } catch (e) {
            // Ignore any exceptions here and return an empty response below
          }
        }
      }

      // Check for exact user search
      if (event.searchType == SearchType.users && searchResponse.users.isEmpty) {
        String? userName = await getLemmyUser(event.query);
        if (userName != null) {
          try {
            Account? account = await fetchActiveProfileAccount();

            final getCommunityResponse = await LemmyClient.instance.lemmyApiV3.run(GetPersonDetails(
              username: userName,
              auth: account?.jwt,
            ));

            searchResponse = searchResponse.copyWith(users: [getCommunityResponse.personView]);
          } catch (e) {
            // Ignore any exceptions here and return an empty response below
          }
        }
      }

      return emit(state.copyWith(
        status: SearchStatus.success,
        communities: prioritizeFavorites(searchResponse.communities.toList(), event.favoriteCommunities),
        users: searchResponse.users,
        comments: searchResponse.comments,
        posts: await parsePostViews(searchResponse.posts),
        page: 2,
      ));
    } catch (e) {
      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _continueSearchEvent(ContinueSearchEvent event, Emitter<SearchState> emit) async {
    int attemptCount = 0;

    try {
      while (attemptCount < 2) {
        try {
          emit(state.copyWith(
            status: SearchStatus.refreshing,
            communities: state.communities,
            users: state.users,
            comments: state.comments,
            posts: state.posts,
          ));

          Account? account = await fetchActiveProfileAccount();
          LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

          SearchResponse searchResponse = await lemmy.run(Search(
            auth: account?.jwt,
            q: event.query,
            page: state.page,
            limit: 15,
            sort: event.sortType,
            listingType: event.listingType,
            type: event.searchType,
            communityId: event.communityId,
            creatorId: event.creatorId,
          ));

          if (searchIsEmpty(event.searchType, searchResponse: searchResponse)) {
            return emit(state.copyWith(status: SearchStatus.done));
          }

          // Append the search results
          state.communities = [...state.communities ?? [], ...searchResponse.communities];
          state.users = [...state.users ?? [], ...searchResponse.users];
          state.comments = [...state.comments ?? [], ...searchResponse.comments];
          state.posts = [...state.posts ?? [], ...await parsePostViews(searchResponse.posts)];

          return emit(state.copyWith(
            status: SearchStatus.success,
            communities: state.communities,
            users: state.users,
            comments: state.comments,
            posts: state.posts,
            page: state.page + 1,
          ));
        } catch (e) {
          attemptCount++;
        }
      }
    } catch (e) {
      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _focusSearchEvent(FocusSearchEvent event, Emitter<SearchState> emit) async {
    emit(state.copyWith(focusSearchId: state.focusSearchId + 1));
  }

  Future<void> _changeCommunitySubsciptionStatusEvent(ChangeCommunitySubsciptionStatusEvent event, Emitter<SearchState> emit) async {
    try {
      if (event.query.isNotEmpty) {
        emit(state.copyWith(status: SearchStatus.refreshing, communities: state.communities));
      }

      Account? account = await fetchActiveProfileAccount();
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;

      if (account?.jwt == null) return;

      await lemmy.run(FollowCommunity(
        auth: account!.jwt!,
        communityId: event.communityId,
        follow: event.follow,
      ));

      // Refetch the status of the community - communityResponse does not return back with the proper subscription status
      GetCommunityResponse fullCommunityView = await lemmy.run(GetCommunity(
        auth: account.jwt,
        id: event.communityId,
      ));

      List<CommunityView> communities;
      if (event.query.isNotEmpty) {
        communities = state.communities ?? [];

        communities = state.communities?.map((CommunityView communityView) {
              if (communityView.community.id == fullCommunityView.communityView.community.id) {
                return fullCommunityView.communityView;
              }
              return communityView;
            }).toList() ??
            [];

        emit(state.copyWith(status: SearchStatus.success, communities: communities));
      } else {
        communities = state.trendingCommunities ?? [];

        communities = state.trendingCommunities?.map((CommunityView communityView) {
              if (communityView.community.id == fullCommunityView.communityView.community.id) {
                return fullCommunityView.communityView;
              }
              return communityView;
            }).toList() ??
            [];

        emit(state.copyWith(status: SearchStatus.trending, trendingCommunities: communities));
      }

      // Delay a bit then refetch the status of the community again for a better chance of getting the right subscribed type
      await Future.delayed(const Duration(seconds: 1));

      fullCommunityView = await lemmy.run(GetCommunity(
        auth: account.jwt,
        id: event.communityId,
      ));

      if (event.query.isNotEmpty) {
        communities = state.communities ?? [];

        communities = state.communities?.map((CommunityView communityView) {
              if (communityView.community.id == fullCommunityView.communityView.community.id) {
                return fullCommunityView.communityView;
              }
              return communityView;
            }).toList() ??
            [];

        return emit(state.copyWith(status: event.query.isNotEmpty ? SearchStatus.success : SearchStatus.trending, communities: communities));
      } else {
        communities = state.trendingCommunities ?? [];

        communities = state.trendingCommunities?.map((CommunityView communityView) {
              if (communityView.community.id == fullCommunityView.communityView.community.id) {
                return fullCommunityView.communityView;
              }
              return communityView;
            }).toList() ??
            [];

        return emit(state.copyWith(status: SearchStatus.trending, trendingCommunities: communities));
      }
    } catch (e) {
      return emit(state.copyWith(status: SearchStatus.failure, errorMessage: e.toString()));
    }
  }

  Future<void> _getTrendingCommunitiesEvent(GetTrendingCommunitiesEvent event, Emitter<SearchState> emit) async {
    try {
      LemmyApiV3 lemmy = LemmyClient.instance.lemmyApiV3;
      Account? account = await fetchActiveProfileAccount();

      ListCommunitiesResponse listCommunitiesResponse = await lemmy.run(ListCommunities(
        type: ListingType.local,
        sort: SortType.active,
        limit: 5,
        auth: account?.jwt,
      ));

      return emit(state.copyWith(status: SearchStatus.trending, trendingCommunities: listCommunitiesResponse.communities));
    } catch (e) {
      // Not the end of the world if we can't load trending
    }
  }

  Future<void> _voteCommentEvent(VoteCommentEvent event, Emitter<SearchState> emit) async {
    final AppLocalizations l10n = AppLocalizations.of(GlobalContext.context)!;

    emit(state.copyWith(status: SearchStatus.performingCommentAction));

    try {
      CommentView updatedCommentView = await voteComment(event.commentId, event.score).timeout(timeout, onTimeout: () {
        throw Exception(l10n.timeoutUpvoteComment);
      });

      // If it worked, update and emit
      CommentView? commentView = state.comments?.firstWhereOrNull((commentView) => commentView.comment.id == event.commentId);
      if (commentView != null) {
        int index = (state.comments?.indexOf(commentView))!;

        List<CommentView> comments = List.from(state.comments ?? []);
        comments.insert(index, updatedCommentView);
        comments.remove(commentView);

        emit(state.copyWith(status: SearchStatus.success, comments: comments));
      }
    } catch (e) {
      // It just fails
    }
  }

  Future<void> _saveCommentEvent(SaveCommentEvent event, Emitter<SearchState> emit) async {
    final AppLocalizations l10n = AppLocalizations.of(GlobalContext.context)!;

    emit(state.copyWith(status: SearchStatus.performingCommentAction));

    try {
      CommentView updatedCommentView = await saveComment(event.commentId, event.save).timeout(timeout, onTimeout: () {
        throw Exception(l10n.timeoutUpvoteComment);
      });

      // If it worked, update and emit
      CommentView? commentView = state.comments?.firstWhereOrNull((commentView) => commentView.comment.id == event.commentId);
      if (commentView != null) {
        int index = (state.comments?.indexOf(commentView))!;

        List<CommentView> comments = List.from(state.comments ?? []);
        comments.insert(index, updatedCommentView);
        comments.remove(commentView);

        emit(state.copyWith(status: SearchStatus.success, comments: comments));
      }
    } catch (e) {
      // It just fails
    }
  }
}
