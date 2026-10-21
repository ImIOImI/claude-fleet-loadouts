import sys, tempfile, unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import triage as t


def note(reason="review_requested", repo="SumerSports/other", url="https://api.github.com/repos/SumerSports/other/pulls/7"):
    return {"id": "1", "reason": reason, "repository": {"full_name": repo, "html_url": f"https://github.com/{repo}"},
            "subject": {"title": "T", "type": "PullRequest", "url": url}}


def st(state="OPEN", url="https://github.com/SumerSports/other/pull/7", reviewers=()):
    return {"state": state, "url": url, "reviewers": set(reviewers)}


HOME = {"sumersports/tofumate"}
LOGIN = "ImIOImI"


class InOrgs(unittest.TestCase):
    def test_no_filter_keeps_everything(self):
        self.assertTrue(t.in_orgs(note(repo="ImIOImI/claude-fleet"), set()))

    def test_filter_matches_owner_case_insensitively(self):
        self.assertTrue(t.in_orgs(note(repo="SumerSports/infra"), {"sumersports"}))
        self.assertFalse(t.in_orgs(note(repo="ImIOImI/claude-fleet"), {"sumersports"}))

    def test_missing_repository_is_outside_any_filter(self):
        self.assertFalse(t.in_orgs({"id": "1"}, {"sumersports"}))


class LoadHomeRepos(unittest.TestCase):
    def test_strips_comments_blank_and_case(self):
        with tempfile.NamedTemporaryFile("w", suffix=".txt", delete=False) as f:
            f.write("# header\nSumerSports/Tofumate  # named\n\n  SumerSports/infra\n")
        self.assertEqual(t.load_home_repos(f.name), {"sumersports/tofumate", "sumersports/infra"})


    def test_missing_file_exits_with_seed_hint(self):
        with self.assertRaises(SystemExit) as cm:
            t.load_home_repos("/nonexistent/home-repos.txt")
        self.assertIn("seed_home_repos.py", str(cm.exception.code))


class ParseSubject(unittest.TestCase):
    def test_pull(self):
        self.assertEqual(t.parse_subject(note()), ("SumerSports", "other", "pr", 7))

    def test_issue(self):
        n = note(url="https://api.github.com/repos/SumerSports/x/issues/12")
        self.assertEqual(t.parse_subject(n), ("SumerSports", "x", "issue", 12))

    def test_non_pr_subject(self):
        self.assertIsNone(t.parse_subject(note(url=None)))
        self.assertIsNone(t.parse_subject(note(url="https://api.github.com/repos/SumerSports/x/releases/9")))


class Classify(unittest.TestCase):
    def c(self, n, s, mentioned=()):
        return t.classify(n, s, HOME, set(mentioned), LOGIN)

    def test_merged_and_closed_done_even_in_home_or_mentioned(self):
        self.assertEqual(self.c(note(reason="mention"), st("MERGED")), ("done", t.RULE_CLOSED))
        self.assertEqual(self.c(note(repo="SumerSports/tofumate"), st("CLOSED")), ("done", t.RULE_CLOSED))

    def test_noise_review_request_done(self):
        self.assertEqual(self.c(note(), st()), ("done", t.RULE_NOISE))

    def test_review_request_outside_home_kept_if_mentioned(self):
        self.assertEqual(self.c(note(), st(), mentioned={"https://github.com/SumerSports/other/pull/7"}), ("keep", 0))

    def test_review_request_outside_home_kept_if_personal(self):
        self.assertEqual(self.c(note(), st(reviewers={"imioimi"})), ("keep", 1))

    def test_review_request_lookup_failed_kept(self):
        self.assertEqual(self.c(note(), None), ("keep", 4))

    def test_home_team_review_request(self):
        self.assertEqual(self.c(note(repo="SumerSports/tofumate"), st()), ("keep", 3))

    def test_mention_reason(self):
        self.assertEqual(self.c(note(reason="mention"), st()), ("keep", 0))

    def test_author(self):
        self.assertEqual(self.c(note(reason="author"), st()), ("keep", 2))

    def test_other_reason_outside_home_kept(self):
        self.assertEqual(self.c(note(reason="subscribed"), st()), ("keep", 4))


class Query(unittest.TestCase):
    SUBJ = [("SumerSports", "a", "pr", 1), ("SumerSports", "b", "issue", 2)]

    def test_build_query_aliases(self):
        q = t.build_query(self.SUBJ)
        self.assertIn('s0: repository(owner: "SumerSports", name: "a") { pullRequest(number: 1)', q)
        self.assertIn('s1: repository(owner: "SumerSports", name: "b") { issue(number: 2)', q)
        self.assertIn("reviewRequests", q)

    def test_parse_states(self):
        data = {
            "s0": {"pullRequest": {"state": "OPEN", "url": "u0", "reviewRequests": {"nodes": [
                {"requestedReviewer": {"login": "ImIOImI"}}, {"requestedReviewer": {}}]}}},
            "s1": None,
        }
        self.assertEqual(t.parse_states(data, self.SUBJ),
                         {self.SUBJ[0]: {"state": "OPEN", "url": "u0", "reviewers": {"imioimi"}}})


class Render(unittest.TestCase):
    def test_html_url_fallback(self):
        self.assertEqual(t.html_url(note(), st(url="u")), "u")
        self.assertEqual(t.html_url(note(), None), "https://github.com/SumerSports/other")

    def test_render(self):
        n = note()
        kept = [(n, 0, "u1")] + [(n, 4, f"x{i}") for i in range(3)]
        out = t.render([(n, t.RULE_CLOSED), (n, t.RULE_NOISE)], kept, limit=2)
        self.assertIn("## Cleared 2", out)
        self.assertIn(f"- {t.RULE_CLOSED}: 1", out)
        self.assertIn("SumerSports/other 2", out)
        self.assertIn("### Mentions (1)", out)
        self.assertIn("- u1 — T (review_requested)", out)
        self.assertIn("- …and 1 more", out)
        self.assertNotIn("Personal review requests", out)


if __name__ == "__main__":
    unittest.main()
