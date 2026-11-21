import pytest

from coachw.api.invites import InviteBook


def test_parse_and_find():
    book = InviteBook.parse(" aaaaaaaaaaaa1:alice:90 , bbbbbbbbbbbb2:bob:30,")
    assert len(book) == 2
    alice = book.find("aaaaaaaaaaaa1")
    assert alice is not None
    assert (alice.name, alice.daily_minutes) == ("alice", 90)
    assert book.find("bbbbbbbbbbbb2").name == "bob"


@pytest.mark.parametrize("code", ["", "aaaaaaaaaaaa", "aaaaaaaaaaaa11", "AAAAAAAAAAAA1"])
def test_unknown_codes(code):
    assert InviteBook.parse("aaaaaaaaaaaa1:alice:90").find(code) is None


def test_empty_config_has_no_invites():
    assert len(InviteBook.parse("")) == 0


@pytest.mark.parametrize(
    "raw",
    [
        "short:alice:90",
        "aaaaaaaaaaaa1:alice",
        "aaaaaaaaaaaa1::90",
        "aaaaaaaaaaaa1:alice:ninety",
        "aaaaaaaaaaaa1:alice:0",
        "aaaaaaaaaaaa1:alice:90,aaaaaaaaaaaa1:bob:30",
    ],
)
def test_rejects_bad_config(raw):
    with pytest.raises(ValueError):
        InviteBook.parse(raw)
