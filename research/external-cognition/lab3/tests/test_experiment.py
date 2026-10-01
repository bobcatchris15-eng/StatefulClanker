import itertools
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import experiment

class AffineEvaluatorTests(unittest.TestCase):
    def test_generator_worlds_are_invertible_and_recover_independently(self):
        for seed in (3101, 3102, 3103):
            case = experiment.make_case(seed)
            obs = case["observations"]
            self.assertEqual(len(obs), 3)
            a,b = obs[1]["xy"][0]-obs[0]["xy"][0], obs[1]["xy"][1]-obs[0]["xy"][1]
            c,d = obs[2]["xy"][0]-obs[0]["xy"][0], obs[2]["xy"][1]-obs[0]["xy"][1]
            self.assertNotEqual((a*d-b*c)%11, 0)
            u,v = case["relation"]["u"],case["relation"]["v"]
            self.assertNotEqual((u[0]*v[1]-u[1]*v[0])%11,0)
            t=case["target"]["uv"]; xy=tuple(case["target"]["xy"])
            brute=[(x,y) for x,y in itertools.product(range(11),repeat=2) if (u[0]*x+u[1]*y+u[2])%11==t[0] and (v[0]*x+v[1]*y+v[2])%11==t[1]]
            self.assertEqual(brute,[xy])
            self.assertEqual(experiment.score_relation({"u":u,"v":v},t,xy),{"correct":True,"solutions":1})
            prompts=experiment.consumer_prompts if False else None

    def test_store_accepts_wrong_valid_relation_and_rejects_bad_patch_atomically(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            accepted=experiment.submit_producer(path,"3101",{"base_version":0,"u":[0,0,0],"v":[0,0,0]})
            self.assertTrue(accepted["accepted"])
            before=path.read_bytes()
            for patch in ({"base_version":1,"u":[1,2],"v":[1,2,3]},{"base_version":0,"u":[1,2,3],"v":[4,5,6]}):
                with self.assertRaises(experiment.StructuralError): experiment.submit_producer(path,"3101",patch)
                self.assertEqual(path.read_bytes(),before)

    def test_revision_cache_invalidation_and_scoring_are_separate(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            experiment.submit_producer(path,"3101",{"base_version":0,"u":[0,0,0],"v":[0,0,0]})
            experiment.cache_answer(path,"3101",{"status":"solved","x":1,"y":2})
            revised={"base_version":1,"u":[2,0,4],"v":[0,3,1],"invalidate":["answer"]}
            self.assertTrue(experiment.submit_revision(path,"3101",revised)["accepted"])
            state=experiment.load_campaign(path)["cases"]["3101"]
            self.assertIsNone(state["cached_answer"]); self.assertEqual(state["version"],2)
            malformed={**revised,"base_version":2,"invalidate":[]}; before=path.read_bytes()
            with self.assertRaises(experiment.StructuralError): experiment.submit_revision(path,"3101",malformed)
            self.assertEqual(path.read_bytes(),before)

    def test_schedule_keeps_case_dependencies_and_omission_has_no_relation(self):
        schedule=experiment._schedule()
        for case in (3101,3102,3103):
            rows=[r for r in schedule if r["case"]==case]
            self.assertEqual([r["stage"] for r in rows][0],"producer")
            self.assertEqual([r["stage"] for r in rows][-2:], ["revision_producer","consumer"])
            self.assertEqual(set(r.get("arm") for r in rows if r["stage"]=="consumer")-{ "revised" }, {"intact","omitted","altered","raw"})
        prompt=experiment._consumer_prompt(None,[2,3])
        self.assertIn("No relation was supplied",prompt)
        self.assertNotIn("u=(0, 0, 0)",prompt)

    def test_conditional_evaluator_scores_against_actual_presented_relation(self):
        altered={"u":[1,2,4],"v":[2,1,3]}
        target=[(1*3+2*5+4)%11,(2*3+1*5+3)%11]
        solutions=experiment.relation_solutions(altered,target)
        self.assertEqual(solutions,[(3,5)])
        self.assertTrue(experiment.response_agreement({"status":"solved","x":3,"y":5},solutions)["agreement"])
        revised={"u":[1,2,6],"v":[2,1,3]}
        revised_solutions=experiment.relation_solutions(revised,target)
        self.assertEqual(revised_solutions,[(0,0)])
        self.assertTrue(experiment.response_agreement({"status":"solved","x":0,"y":0},revised_solutions)["agreement"])
        self.assertNotEqual(revised_solutions,solutions)

    def test_revised_prompt_is_only_emitted_after_revision(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            experiment.submit_producer(path,"3101",{"base_version":0,"u":[1,2,3],"v":[2,1,4]})
            first=experiment.consumer_prompts(path,"3101")
            self.assertEqual(set(first),{"intact","omitted","altered","raw"})
            experiment.submit_revision(path,"3101",{"base_version":1,"u":[1,2,5],"v":[2,1,4],"invalidate":["answer"]})
            revised=experiment.consumer_prompts(path,"3101")
            self.assertEqual(set(revised),{"revised"})
            text=Path(revised["revised"]).read_text(encoding="utf-8")
            self.assertNotIn("Cached",text)
            self.assertIn("Relation:",text)

    def test_evaluate_distinguishes_altered_and_revision_conditional_from_true_world(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            world=experiment.make_case(3101); u=world["relation"]["u"][:]; v=world["relation"]["v"][:]
            experiment.submit_producer(path,"3101",{"base_version":0,"u":u,"v":v})
            altered={"u":u[:],"v":v[:]}; altered["u"][2]=(altered["u"][2]+1)%11
            target=world["target"]["uv"]; candidate=experiment.relation_solutions(altered,target)[0]
            experiment.submit_consumer(path,"3101","altered",{"status":"solved","x":candidate[0],"y":candidate[1]})
            ru=u[:]; ru[2]=(ru[2]+1)%11
            wrong_revision={"base_version":1,"u":ru,"v":v,"invalidate":["answer"]}
            experiment.submit_revision(path,"3101",wrong_revision)
            revised_candidate=experiment.relation_solutions({"u":ru,"v":v},target)[0]
            experiment.submit_consumer(path,"3101","revised",{"status":"solved","x":revised_candidate[0],"y":revised_candidate[1]})
            result=experiment.evaluate(path)["cases"]["3101"]
            self.assertTrue(result["arms"]["altered"]["response_correct_under_conditioned_relation"])
            self.assertFalse(result["arms"]["altered"]["true_world_correct"])
            self.assertTrue(result["revision"]["consumer_agreement_with_submitted_revision"])
            self.assertFalse(result["revision"]["consumer_true_world_correct"])

    def test_omitted_concrete_answers_are_scored_against_true_world(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            world=experiment.make_case(3101); u=world["relation"]["u"]; v=world["relation"]["v"]
            experiment.submit_producer(path,"3101",{"base_version":0,"u":u,"v":v})
            x,y=world["target"]["xy"]
            experiment.submit_consumer(path,"3101","omitted",{"status":"solved","x":x,"y":y})
            result=experiment.evaluate(path)["cases"]["3101"]["arms"]["omitted"]
            self.assertTrue(result["true_world_correct"])
            campaign=experiment.load_campaign(path)
            campaign["cases"]["3101"]["consumer_raw"].pop("omitted")
            experiment._write(path,campaign)
            experiment.submit_consumer(path,"3101","omitted",{"status":"solved","x":(x+1)%11,"y":y})
            result=experiment.evaluate(path)["cases"]["3101"]["arms"]["omitted"]
            self.assertFalse(result["true_world_correct"])
            campaign=experiment.load_campaign(path)
            campaign["cases"]["3101"]["consumer_raw"].pop("omitted")
            experiment._write(path,campaign)
            experiment.submit_consumer(path,"3101","omitted",{"status":"underdetermined"})
            result=experiment.evaluate(path)["cases"]["3101"]["arms"]["omitted"]
            self.assertIsNone(result["true_world_correct"])

    def test_revision_correctness_uses_intended_revised_world_same_target(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            world=experiment.make_case(3103); u=world["relation"]["u"][:]; v=world["relation"]["v"][:]
            experiment.submit_producer(path,"3103",{"base_version":0,"u":u,"v":v})
            intended_u=u[:]; intended_u[2]=(intended_u[2]+2)%11
            experiment.submit_revision(path,"3103",{"base_version":1,"u":intended_u,"v":v,"invalidate":["answer"]})
            expected=experiment.relation_solutions({"u":intended_u,"v":v},world["target"]["uv"])
            self.assertEqual(expected,[(4,10)])
            experiment.submit_consumer(path,"3103","revised",{"status":"solved","x":4,"y":10})
            result=experiment.evaluate(path)["cases"]["3103"]["revision"]
            self.assertTrue(result["consumer_agreement_with_submitted_revision"])
            self.assertTrue(result["consumer_intended_revised_world_correct"])
            self.assertFalse(result["consumer_true_world_correct"])

    def test_wrong_accepted_revision_follower_is_not_intended_world_correct(self):
        with tempfile.TemporaryDirectory() as tmp:
            path=Path(tmp)/"campaign.json"; experiment.prepare(path)
            world=experiment.make_case(3101); u=world["relation"]["u"][:]; v=world["relation"]["v"][:]
            experiment.submit_producer(path,"3101",{"base_version":0,"u":u,"v":v})
            wrong_u=u[:]; wrong_u[2]=(wrong_u[2]+1)%11
            experiment.submit_revision(path,"3101",{"base_version":1,"u":wrong_u,"v":v,"invalidate":["answer"]})
            wrong_solution=experiment.relation_solutions({"u":wrong_u,"v":v},world["target"]["uv"])
            self.assertEqual(wrong_solution,[(6,2)])
            experiment.submit_consumer(path,"3101","revised",{"status":"solved","x":6,"y":2})
            result=experiment.evaluate(path)["cases"]["3101"]["revision"]
            self.assertTrue(result["consumer_agreement_with_submitted_revision"])
            self.assertFalse(result["consumer_intended_revised_world_correct"])

    def test_consumer_response_schema_is_strict(self):
        self.assertTrue(experiment.validate_consumer_response({"status":"solved","x":0,"y":10}))
        self.assertTrue(experiment.validate_consumer_response({"status":"underdetermined"}))
        for value in ({"status":"solved","x":0},{"status":"solved","x":True,"y":1},{"status":"underdetermined","x":0},{"status":"other"}):
            self.assertFalse(experiment.validate_consumer_response(value))

if __name__=="__main__": unittest.main()
